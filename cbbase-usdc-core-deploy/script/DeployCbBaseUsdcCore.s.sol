// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////////////////
    Bizantine cbBase USDC CORE — IPOR Fusion Plasma Vault deploy (Base 8453)
    Spec v0.7 | ticker bizcbBaseUSDC | asset USDC (6dp)

    CORRECTED SCAFFOLD. Every symbol/signature below was verified against a
    clone of IPOR-Labs/ipor-fusion (see VERIFY.md "Repo verification" for the
    exact discrepancies fixed vs. the original scaffold). Do NOT broadcast
    until every `CONFIRM_WITH_PAVEL` / address(0) slot is filled and the
    pre-flight gate in DEPLOY_PROMPT.md §0 is all-green.

    ── Authorization model (verified in IporFusionAccessManagerInitializerLibV1
       + FusionFactoryLogicLib + TestConfigurationExample.t.sol) ──
      clone(owner_) grants ONLY OWNER_ROLE to owner_. Nobody holds ATOMIST /
      FUSE_MANAGER / CONFIG_INSTANT_WITHDRAWAL_FUSES / PRICE_ORACLE_MIDDLEWARE_MANAGER.
      Function → role:
        addFuses / addBalanceFuse / grantMarketSubstrates .. FUSE_MANAGER_ROLE(300)
        setupMarketsLimits / activateMarketsLimits ......... ATOMIST_ROLE(100)
        setPriceOracleMiddleware / convert / fees .......... ATOMIST_ROLE(100)
        configureInstantWithdrawalFuses ................... CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE(900)
        priceManager.setAssetsPriceSources ................ PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE(1200)
      Admin graph: OWNER admins ATOMIST; ATOMIST admins FUSE_MANAGER, ALPHA,
      CONFIG_INSTANT, CLAIM/TRANSFER_REWARDS, PRICE_ORACLE_MIDDLEWARE_MANAGER.

    ── Deploy identity (CONFIRM_WITH_PAVEL) ──
      A forge script broadcasts from ONE EOA; it cannot act as the Owner Safe.
      This script therefore clones with owner_ = DEPLOYER, performs all config
      as DEPLOYER (granting itself the temp roles the owner is allowed to grant),
      then hands OWNER_ROLE to the Owner Safe + ATOMIST to the timelocked Atomist
      Safe and REVOKES its own temp roles at the end. If IPOR instead expects the
      Owner Safe to run config via a batched multisig tx, clone with owner_ =
      OWNER_SAFE and export steps 2-9 as Safe transactions instead.
//////////////////////////////////////////////////////////////////////////*/

import {Script, console2} from "forge-std/Script.sol";

import {FusionFactory} from "contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "contracts/factory/lib/FusionFactoryLogicLib.sol";
import {IPlasmaVaultGovernance} from "contracts/interfaces/IPlasmaVaultGovernance.sol";
import {MarketLimit} from "contracts/libraries/AssetDistributionProtectionLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {FeeManager} from "contracts/managers/fee/FeeManager.sol";
import {RecipientFee} from "contracts/managers/fee/FeeManagerFactory.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddlewareManager} from "contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {Roles} from "contracts/libraries/Roles.sol";

contract DeployCbBaseUsdcCore is Script {
    // ───────────────────────────── constants (locked, spec v0.7) ─────────────────────────────
    string  constant NAME   = "Bizantine cbBase USDC CORE";
    string  constant SYMBOL = "bizcbBaseUSDC";
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base native USDC (6dp)
    uint256 constant REDEMPTION_DELAY = 3600; // >0 required (anti-sandwich)

    // Idle USDC accounting market (verified: IporFusionMarkets.ERC20_VAULT_BALANCE == 7).
    uint256 constant MID_ERC20_IDLE = 7;

    // governance (EIP-55 valid; confirm control on Base — see gate §0.2)
    address constant OWNER_SAFE = 0x3FCA4624A7fc97301daffec96834939dE6671474;
    address constant ATOMIST    = 0x81Bd70230a9D0928095364E3E72a900727e4Af6e;
    address constant FEE_RECIP  = 0xB52e1E7C34887D966A03E8188ed338f098dAD723;
    uint32  constant ATOMIST_DELAY = 86400; // 24h timelock (172800 = 48h) — CONFIRM

    // ── Fees are 2-DECIMAL PERCENT (100 = 1.00%, 1000 = 10.00%) — NOT 1e18. ──
    // FeeManager total = IPOR DAO fee (fixed by daoFeePackageIndex at clone)
    //                  + sum of recipient fees set here. So Bizantine's recipient
    // fee = spec total − DAO portion. DAO portion is unknown until Pavel confirms
    // the package, hence the sentinels below force an explicit value before broadcast.
    uint256 constant SPEC_TOTAL_PERF = 1000; // 10.00% total performance fee (spec)
    uint256 constant SPEC_TOTAL_MGMT = 50;   // 0.50%  total management fee (spec)
    uint256 constant DAO_PERF_FEE = type(uint256).max; // CONFIRM_WITH_PAVEL (2dp %) for daoFeePackageIndex
    uint256 constant DAO_MGMT_FEE = type(uint256).max; // CONFIRM_WITH_PAVEL (2dp %)

    // Morpho markets (bytes32 substrate = Morpho market id). VERIFIED live on Base 2026-07-07
    // via Morpho API: all six are USDC-loan markets with the expected cb* collateral.
    bytes32 constant M_CBBTC  = 0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836;
    bytes32 constant M_CBETH  = 0x1c21c59df9db44bf6f645d854ee710a8ca17b479451447e9f56758aee10a2fad;
    bytes32 constant M_CBXRP  = 0xd4a903dc6d949519060c7707f9604fdc9772c046e05c2e3a8fce0bd7196e4109;
    bytes32 constant M_CBDOGE = 0x73527ddd796e6d4f48387adaae36f6f3d49d606d7f2a15eb0c931416a58875d8;
    bytes32 constant M_CBADA  = 0xd7520ad198b497b6eb75bc690268f4597630dbc12e305e9d4105843bab36e41d;
    bytes32 constant M_CBLTC  = 0x9125d0fa03c3137166df68bcc72283477830de2a4a5536512374c573ad4583c3;

    // Fusion internal marketIds (one per cb market => per-market caps are on-chain enforceable)
    uint256 constant MID_CBBTC=1; uint256 constant MID_CBETH=2; uint256 constant MID_CBXRP=3;
    uint256 constant MID_CBDOGE=4; uint256 constant MID_CBADA=5; uint256 constant MID_CBLTC=6;
    uint256 constant MID_COMPOUND=10; uint256 constant MID_AAVE=11;

    // ───────────────────── ADDRESSES (verified from ipor-abi / fill before broadcast) ─────────────────────
    // VERIFIED from IPOR-Labs/ipor-abi (mainnet-base-fusion/addresses.json), surfaced via mcp.ipor.io:
    address constant FUSION_FACTORY = 0x1455717668fA96534f675856347A973fA907e922; // IporFusionFactoryProxy (Base) — VERIFIED
    address constant AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D; // VERIFIED (used to build the Aave fuse instance; not called directly here)

    uint256 constant DAO_FEE_PACKAGE_INDEX = type(uint256).max; // CONFIRM_WITH_PAVEL (sentinel forces an explicit value)

    // Per-marketId fuse INSTANCES. A supply fuse's marketId is IMMUTABLE, so Option A
    // (per-market caps) requires ONE MorphoSupply+Balance instance per marketId 1-6, plus
    // Compound(10) and Aave(11). ipor-abi ships only single shared instances (one SupplyFuseMorpho,
    // no CompoundV3-USDC fuse on Base) — so IPOR must DEPLOY these per-market instances. Leave
    // address(0) until Pavel provides them. (If IPOR won't, fall back to Option B: one Morpho
    // marketId + aggregate cap — DEPLOY_PROMPT §2.)
    address constant SUPPLY_CBBTC=address(0);  address constant BAL_CBBTC=address(0);
    address constant SUPPLY_CBETH=address(0);  address constant BAL_CBETH=address(0);
    address constant SUPPLY_CBXRP=address(0);  address constant BAL_CBXRP=address(0);
    address constant SUPPLY_CBDOGE=address(0); address constant BAL_CBDOGE=address(0);
    address constant SUPPLY_CBADA=address(0);  address constant BAL_CBADA=address(0);
    address constant SUPPLY_CBLTC=address(0);  address constant BAL_CBLTC=address(0);
    address constant SUPPLY_COMPOUND=address(0); address constant BAL_COMPOUND=address(0);
    address constant SUPPLY_AAVE=address(0);     address constant BAL_AAVE=address(0);
    // Mandatory idle-USDC accounting balance fuse for ERC20_VAULT_BALANCE (market 7).
    // Verified required: without it the vault cannot track idle USDC in NAV / withdrawals.
    address constant BAL_ERC20_IDLE=address(0);  // CONFIRM_WITH_PAVEL (ERC20 balance fuse instance)

    address constant ALPHA_IPOR = address(0);   // IPOR Alpha service — CONFIRM_WITH_PAVEL
    address constant GUARDIAN_HN = address(0);  // Hypernative guardian — TBD

    // Optional explicit USDC/USD price source. The factory already wires the vault to the shared
    // PriceOracleMiddleware at clone; only set this if VERIFY shows priceOf(USDC) is unpriced.
    address constant USDC_USD_FEED = address(0); // CONFIRM (skip when address(0))

    // scheduled withdrawal window (MANDATORY > 0) on the WithdrawManager (Tier2/3 are non-instant).
    uint256 constant WITHDRAW_WINDOW_SECONDS = 0; // CONFIRM_WITH_PAVEL duration; must be > 0 before broadcast

    // instant-withdraw amount slot (params[0] set at runtime, 0 at config time)
    bytes32 constant AMT = bytes32(0);

    function run() external {
        // ── pre-flight guards (fail fast rather than half-deploying) ──
        require(FUSION_FACTORY != address(0), "set FUSION_FACTORY");
        require(DAO_FEE_PACKAGE_INDEX != type(uint256).max, "set DAO_FEE_PACKAGE_INDEX");
        require(DAO_PERF_FEE != type(uint256).max && DAO_MGMT_FEE != type(uint256).max, "set DAO fee portions");
        require(DAO_PERF_FEE <= SPEC_TOTAL_PERF && DAO_MGMT_FEE <= SPEC_TOTAL_MGMT, "DAO fee exceeds spec total");
        require(ALPHA_IPOR != address(0) && GUARDIAN_HN != address(0), "set ALPHA/GUARDIAN");
        require(WITHDRAW_WINDOW_SECONDS > 0, "set WITHDRAW_WINDOW_SECONDS > 0");
        _requireFusesSet();

        // Bizantine's recipient fee slice so that (DAO + recipient) == spec total.
        uint256 bizPerf = SPEC_TOTAL_PERF - DAO_PERF_FEE;
        uint256 bizMgmt = SPEC_TOTAL_MGMT - DAO_MGMT_FEE;

        vm.startBroadcast();
        // Resolve the actual broadcasting EOA (robust under --account/keystore; using msg.sender
        // here would capture forge's default sender, not the signer, and mis-set the clone owner).
        (, address deployer, ) = vm.readCallers();

        // 1) Deploy the full Fusion instance. owner_ = deployer so this script can run config;
        //    OWNER_ROLE is handed to OWNER_SAFE in step 10.
        FusionFactoryLogicLib.FusionInstance memory f = FusionFactory(FUSION_FACTORY).clone(
            NAME, SYMBOL, USDC, REDEMPTION_DELAY, deployer, DAO_FEE_PACKAGE_INDEX
        );
        IPlasmaVaultGovernance vault = IPlasmaVaultGovernance(f.plasmaVault);
        IporFusionAccessManager am = IporFusionAccessManager(f.accessManager);
        console2.log("plasmaVault", f.plasmaVault);
        console2.log("accessManager", f.accessManager);
        console2.log("feeManager", f.feeManager);
        console2.log("withdrawManager", f.withdrawManager);
        console2.log("priceManager", f.priceManager);

        // 1a) Grant the temporary config roles to the deployer (delay 0).
        //     owner→ATOMIST, then ATOMIST→FUSE_MANAGER/CONFIG_INSTANT/PRICE_MANAGER.
        am.grantRole(Roles.ATOMIST_ROLE, deployer, 0);
        am.grantRole(Roles.FUSE_MANAGER_ROLE, deployer, 0);
        am.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer, 0);
        am.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer, 0);

        // 2) Register all supply + balance fuses (FUSE_MANAGER_ROLE).
        address[] memory fuses = new address[](8);
        fuses[0]=SUPPLY_CBBTC; fuses[1]=SUPPLY_CBETH; fuses[2]=SUPPLY_CBXRP; fuses[3]=SUPPLY_CBDOGE;
        fuses[4]=SUPPLY_CBADA; fuses[5]=SUPPLY_CBLTC; fuses[6]=SUPPLY_COMPOUND; fuses[7]=SUPPLY_AAVE;
        vault.addFuses(fuses);
        vault.addBalanceFuse(MID_CBBTC, BAL_CBBTC);
        vault.addBalanceFuse(MID_CBETH, BAL_CBETH);
        vault.addBalanceFuse(MID_CBXRP, BAL_CBXRP);
        vault.addBalanceFuse(MID_CBDOGE, BAL_CBDOGE);
        vault.addBalanceFuse(MID_CBADA, BAL_CBADA);
        vault.addBalanceFuse(MID_CBLTC, BAL_CBLTC);
        vault.addBalanceFuse(MID_COMPOUND, BAL_COMPOUND);
        vault.addBalanceFuse(MID_AAVE, BAL_AAVE);
        vault.addBalanceFuse(MID_ERC20_IDLE, BAL_ERC20_IDLE); // idle USDC accounting (market 7)

        // 3) Substrate allowlist (FUSE_MANAGER_ROLE). Morpho = bytes32 market id; venue = asset addr as bytes32.
        vault.grantMarketSubstrates(MID_CBBTC,  _one(M_CBBTC));
        vault.grantMarketSubstrates(MID_CBETH,  _one(M_CBETH));
        vault.grantMarketSubstrates(MID_CBXRP,  _one(M_CBXRP));
        vault.grantMarketSubstrates(MID_CBDOGE, _one(M_CBDOGE));
        vault.grantMarketSubstrates(MID_CBADA,  _one(M_CBADA));
        vault.grantMarketSubstrates(MID_CBLTC,  _one(M_CBLTC));
        vault.grantMarketSubstrates(MID_COMPOUND, _one(_a2b(USDC)));
        vault.grantMarketSubstrates(MID_AAVE,     _one(_a2b(USDC)));
        vault.grantMarketSubstrates(MID_ERC20_IDLE, _one(_a2b(USDC)));

        // 3a) Dependency balance graph: interacting with any lending market moves USDC in/out of the
        //     idle (ERC20_VAULT_BALANCE=7) balance, so each depends on market 7. Verified pattern in
        //     TestConfigurationExample.t.sol (updateDependencyBalanceGraphs).
        uint256[] memory depMarkets = new uint256[](8);
        depMarkets[0]=MID_CBBTC; depMarkets[1]=MID_CBETH; depMarkets[2]=MID_CBXRP; depMarkets[3]=MID_CBDOGE;
        depMarkets[4]=MID_CBADA; depMarkets[5]=MID_CBLTC; depMarkets[6]=MID_COMPOUND; depMarkets[7]=MID_AAVE;
        uint256[][] memory deps = new uint256[][](8);
        for (uint256 i = 0; i < 8; i++) { uint256[] memory d = new uint256[](1); d[0]=MID_ERC20_IDLE; deps[i]=d; }
        vault.updateDependencyBalanceGraphs(depMarkets, deps);

        // 4) Per-market caps (1e18 = 100%) then ACTIVATE (ATOMIST_ROLE).
        //    NOTE: these are independent per-market ceilings; their sum (161%) can exceed 100%.
        //    Aggregate/tier caps (Morpho ≤80%, T2+3 ≤45%, T3 ≤15%, idle ≥5%) are NOT on-chain —
        //    they live in IPOR's Alpha policy + Hypernative monitoring (DEPLOY_PROMPT §3).
        MarketLimit[] memory lim = new MarketLimit[](8);
        lim[0]=MarketLimit(MID_CBBTC,0.50e18);  lim[1]=MarketLimit(MID_CBETH,0.25e18);
        lim[2]=MarketLimit(MID_CBXRP,0.22e18);  lim[3]=MarketLimit(MID_CBDOGE,0.08e18);
        lim[4]=MarketLimit(MID_CBADA,0.06e18);  lim[5]=MarketLimit(MID_CBLTC,0.05e18);
        lim[6]=MarketLimit(MID_COMPOUND,0.20e18); lim[7]=MarketLimit(MID_AAVE,0.25e18);
        vault.setupMarketsLimits(lim);
        vault.activateMarketsLimits(); // REQUIRED — setupMarketsLimits alone does not enforce caps.

        // 5) Price oracle. The factory already wires the vault to the shared PriceOracleMiddleware at
        //    clone (via f.priceManager) — do NOT call vault.setPriceOracleMiddleware here. Only register
        //    a USDC/USD source if VERIFY shows USDC is unpriced by the shared middleware.
        if (USDC_USD_FEED != address(0)) {
            address[] memory assets = new address[](1); assets[0]=USDC;
            address[] memory sources = new address[](1); sources[0]=USDC_USD_FEED;
            PriceOracleMiddlewareManager(f.priceManager).setAssetsPriceSources(assets, sources);
        }

        // 6) Instant-withdraw waterfall (CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE):
        //    idle -> Aave -> Compound -> cbBTC -> cbETH. Tier2/3 (3-6) excluded.
        InstantWithdrawalFusesParamsStruct[] memory w = new InstantWithdrawalFusesParamsStruct[](4);
        w[0]=InstantWithdrawalFusesParamsStruct(SUPPLY_AAVE,     _p(AMT, _a2b(USDC)));
        w[1]=InstantWithdrawalFusesParamsStruct(SUPPLY_COMPOUND, _p(AMT, _a2b(USDC)));
        w[2]=InstantWithdrawalFusesParamsStruct(SUPPLY_CBBTC,    _p(AMT, M_CBBTC));
        w[3]=InstantWithdrawalFusesParamsStruct(SUPPLY_CBETH,    _p(AMT, M_CBETH));
        vault.configureInstantWithdrawalFuses(w);
        // CONFIRM exact params[] layout per fuse against ipor-fusion docs (order of asset/marketId after amount).

        // 6a) Mandatory scheduled withdrawal window (> 0) on the WithdrawManager (ATOMIST_ROLE).
        WithdrawManager(f.withdrawManager).updateWithdrawWindow(WITHDRAW_WINDOW_SECONDS);

        // 7) Fees (ATOMIST_ROLE). 2-decimal percent. Recipient = Bizantine slice; DAO slice comes
        //    from the clone package. Total charged = DAO + this slice = spec total.
        RecipientFee[] memory perf = new RecipientFee[](1);
        perf[0]=RecipientFee(FEE_RECIP, bizPerf);
        FeeManager(f.feeManager).updatePerformanceFee(perf);
        RecipientFee[] memory mgmt = new RecipientFee[](1);
        mgmt[0]=RecipientFee(FEE_RECIP, bizMgmt);
        FeeManager(f.feeManager).updateManagementFee(mgmt);

        // 8) Grant the production roles.
        am.grantRole(Roles.ATOMIST_ROLE, ATOMIST, ATOMIST_DELAY);   // timelocked Atomist Safe
        am.grantRole(Roles.ALPHA_ROLE, ALPHA_IPOR, 0);
        am.grantRole(Roles.CLAIM_REWARDS_ROLE, ALPHA_IPOR, 0);
        am.grantRole(Roles.TRANSFER_REWARDS_ROLE, ALPHA_IPOR, 0);
        am.grantRole(Roles.GUARDIAN_ROLE, GUARDIAN_HN, 0);
        am.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, ATOMIST, ATOMIST_DELAY); // Atomist, not Alpha

        // 9) Hand OWNER_ROLE to the Owner Safe (OWNER_ROLE is self-administered).
        am.grantRole(Roles.OWNER_ROLE, OWNER_SAFE, 0);

        // 10) Drop the deployer's temporary authority (config + owner). Order matters: revoke the
        //     ATOMIST-administered roles first, then ATOMIST, then the deployer's OWNER_ROLE last.
        am.revokeRole(Roles.FUSE_MANAGER_ROLE, deployer);
        am.revokeRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer);
        am.revokeRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer);
        am.revokeRole(Roles.ATOMIST_ROLE, deployer);
        am.revokeRole(Roles.OWNER_ROLE, deployer);
        // NOTE: vault stays PRIVATE (deposits blocked) until VERIFY passes and ATOMIST calls
        // convertToPublicVault() + enableTransferShares() per the final deposits decision.

        vm.stopBroadcast();
        console2.log("DONE. Verify against VERIFY.md before seeding TVL / opening.");
    }

    // ── helpers ──
    function _requireFusesSet() internal pure {
        require(SUPPLY_CBBTC!=address(0) && BAL_CBBTC!=address(0), "set cbBTC fuses");
        require(SUPPLY_CBETH!=address(0) && BAL_CBETH!=address(0), "set cbETH fuses");
        require(SUPPLY_CBXRP!=address(0) && BAL_CBXRP!=address(0), "set cbXRP fuses");
        require(SUPPLY_CBDOGE!=address(0) && BAL_CBDOGE!=address(0), "set cbDOGE fuses");
        require(SUPPLY_CBADA!=address(0) && BAL_CBADA!=address(0), "set cbADA fuses");
        require(SUPPLY_CBLTC!=address(0) && BAL_CBLTC!=address(0), "set cbLTC fuses");
        require(SUPPLY_COMPOUND!=address(0) && BAL_COMPOUND!=address(0), "set Compound fuses");
        require(SUPPLY_AAVE!=address(0) && BAL_AAVE!=address(0), "set Aave fuses");
        require(BAL_ERC20_IDLE!=address(0), "set idle balance fuse");
    }
    function _one(bytes32 x) internal pure returns (bytes32[] memory a){ a=new bytes32[](1); a[0]=x; }
    function _p(bytes32 amt, bytes32 sub) internal pure returns (bytes32[] memory a){ a=new bytes32[](2); a[0]=amt; a[1]=sub; }
    function _a2b(address x) internal pure returns (bytes32){ return bytes32(uint256(uint160(x))); }
}
