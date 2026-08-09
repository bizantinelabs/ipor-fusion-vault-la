// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////////////////
    Bizantine cbBase USDC CORE — IPOR Fusion Plasma Vault deploy (Base 8453)
    Spec v0.8 | ticker bizcbBaseUSDC | asset USDC (6dp)

    marketId model (contracts/libraries/IporFusionMarkets.sol):
      MORPHO = 14 (single market; all 6 cb markets are substrates, balance summed)
      AAVE_V3 = 1
      COMPOUND_V3_USDC = 2  -> NO canonical fuse deployed on Base (see below). LEG DISABLED.
      ERC20_VAULT_BALANCE (idle) = 7 -> NOT used: idle USDC is the underlying and is counted
        natively in NAV; Erc20BalanceFuse explicitly EXCLUDES the underlying, so a market-7
        fuse would track nothing here. (IPOR's "add for each vault" guidance applies to vaults
        holding NON-underlying ERC20s, e.g. USDT/reward tokens — not this vault.)

    => Launch config = Morpho(14) + Aave(1). On-chain caps are AGGREGATE per protocol
       (Morpho 80% / Aave 25%). Per-cb caps (cbBTC 50%, cbXRP 22%, ...) + Compound's former
       7% target are Alpha policy + Hypernative, NOT on-chain.

    ── ADDRESSES VERIFIED ON-CHAIN 2026-07-07 (Base RPC eth_call), source = IPOR ipor-abi
       registry mainnet/mainnet-base-fusion/addresses.json ──
      FusionFactory (IporFusionFactoryProxy) 0x1455717668fA96534f675856347A973fA907e922
        getDaoFeePackagesLength()=3 · getWithdrawWindowInSeconds()=86400 (default; we override 48h)
      SupplyFuseMorpho  0xae93EF3cf337b9599F0dfC12520c3C281637410F  MARKET_ID()=14 MORPHO()=0xBBBB..FFCb
      BalanceFuseMorpho 0x7916856E11E0CA021967D0D4daC49D737b7d73d5  MARKET_ID()=14
      SupplyFuseAaveV3  0x26fD6EF391E98C78CfCA27e00c3d15be4D941625  MARKET_ID()=1  PROVIDER()=0xe20f..d64D
      BalanceFuseAaveV3 0xf53f3EaFfDf67539256365cA7299540A98b60BA9  MARKET_ID()=1
      AaveV3PoolAddressesProvider 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D  getPool()=0xA238..d1c5
        (provider is baked into the Aave fuse's immutable; the deploy path does not pass it)
      Compound USDC (marketId 2): registry has ONLY SupplyFuseCompoundV3WEth 0xD72D..b72b
        (verified MARKET_ID()=26, COMPOUND_BASE_TOKEN()=WETH) -> no USDC fuse exists. See RESOLUTIONS.
//////////////////////////////////////////////////////////////////////////*/

import {Script, console2} from "forge-std/Script.sol";
import {FusionFactory} from "contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "contracts/factory/lib/FusionFactoryLogicLib.sol";
import {IPlasmaVaultGovernance} from "contracts/interfaces/IPlasmaVaultGovernance.sol";
import {MarketLimit} from "contracts/libraries/AssetDistributionProtectionLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManager} from "contracts/managers/fee/FeeManager.sol";
import {RecipientFee} from "contracts/managers/fee/FeeManagerFactory.sol";
import {Roles} from "contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";

contract DeployCbBaseUsdcCore is Script {
    // ── locked identity (immutable post-clone) ──
    string  constant NAME   = "Bizantine cbBase USDC CORE";
    string  constant SYMBOL = "bizcbBaseUSDC";
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC (6dp)
    uint256 constant REDEMPTION_DELAY = 3600;   // >0 anti-sandwich (separate from withdraw window)
    uint256 constant WITHDRAW_WINDOW  = 172800; // 48h scheduled-withdraw window (factory default is 86400)

    // ── governance (EOA / Fordefi MPC — same address on Base, verified no Safe contract) ──
    address constant OWNER_SAFE = 0x327d70c3E11CD26f3f11295459e6f4fbB6071474; // Fordefi (Noah 2026-07-07)
    address constant ATOMIST    = 0x81Bd70230a9D0928095364E3E72a900727e4Af6e;
    address constant FEE_RECIP  = 0xB52e1E7C34887D966A03E8188ed338f098dAD723;
    uint32  constant ATOMIST_DELAY = 86400; // 24h (172800 = 48h)

    // ── FEES — scale is PERCENTAGE WITH 2 DECIMALS: 10000 = 100%, 100 = 1% (FeeManager) ──
    //   Bizantine's cut is ON TOP of IPOR's DAO package. DECISION (Noah 2026-07-07):
    //   Bizantine = 0% management, 10% performance. With DAO_FEE_PACKAGE_INDEX=1 (0.30%/2.00%),
    //   LP-facing TOTAL = perf 10% + 2% = 12%   |   mgmt 0% + 0.3% = 0.3%.
    uint256 constant PERF_FEE = 1000; // 10.00% (Bizantine cut)
    uint256 constant MGMT_FEE = 0;    //  0.00% (Bizantine cut — IPOR DAO 0.30% still applies)
    //   DAO package read on-chain: [0]=0.05%/10%  [1]=0.30%/2%(standard)  [2]=0.50%/0%  recipient=IPOR DAO
    uint256 constant DAO_FEE_PACKAGE_INDEX = 1; // standard; CONFIRM entitlement w/ Pavel

    // ── marketIds ──
    uint256 constant MID_AAVE   = 1;   // IporFusionMarkets.AAVE_V3
    uint256 constant MID_MORPHO = 14;  // IporFusionMarkets.MORPHO
    // uint256 constant MID_COMPOUND = 2; // COMPOUND_V3_USDC — leg disabled (no Base fuse)
    // uint256 constant MID_IDLE     = 7; // ERC20_VAULT_BALANCE — not used (idle USDC native)

    // ── Morpho market ids (bytes32 substrates under MID_MORPHO). Live 2026-07-06. ──
    bytes32 constant M_CBBTC  = 0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836;
    bytes32 constant M_CBETH  = 0x1c21c59df9db44bf6f645d854ee710a8ca17b479451447e9f56758aee10a2fad;
    bytes32 constant M_CBXRP  = 0xd4a903dc6d949519060c7707f9604fdc9772c046e05c2e3a8fce0bd7196e4109;
    bytes32 constant M_CBDOGE = 0x73527ddd796e6d4f48387adaae36f6f3d49d606d7f2a15eb0c931416a58875d8;
    bytes32 constant M_CBADA  = 0xd7520ad198b497b6eb75bc690268f4597630dbc12e305e9d4105843bab36e41d;
    bytes32 constant M_CBLTC  = 0x9125d0fa03c3137166df68bcc72283477830de2a4a5536512374c573ad4583c3;

    // ── canonical Base fuse instances (VERIFIED ON-CHAIN 2026-07-07 — see header) ──
    address constant FUSION_FACTORY = 0x1455717668fA96534f675856347A973fA907e922;
    address constant SUPPLY_MORPHO  = 0xae93EF3cf337b9599F0dfC12520c3C281637410F; // MorphoSupplyFuse(14)
    address constant BAL_MORPHO     = 0x7916856E11E0CA021967D0D4daC49D737b7d73d5; // MorphoBalanceFuse(14)
    address constant SUPPLY_AAVE    = 0x26fD6EF391E98C78CfCA27e00c3d15be4D941625; // AaveV3SupplyFuse(1)
    address constant BAL_AAVE       = 0xf53f3EaFfDf67539256365cA7299540A98b60BA9; // AaveV3BalanceFuse(1)
    address constant AAVE_PROVIDER  = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D; // record only (baked into fuse)
    // Compound USDC leg DISABLED — no fuse on Base. To enable, get IPOR to deploy
    // CompoundV3SupplyFuse(2)+CompoundV3BalanceFuse(2) for comet 0xb125E6687d4313864e53df431d5425969c15Eb2F.

    address constant ALPHA_IPOR  = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6; // IPOR Alpha (vault wizard)
    address constant GUARDIAN_HN = 0x7420fE73F5c21D7d32E7a15B7eAAF7dB9ccad1Df; // Hypernative guardian

    bytes32 constant AMT = bytes32(0); // instant-withdraw amount slot (runtime)

    function run() external {
        require(FUSION_FACTORY != address(0), "set FUSION_FACTORY");
        require(SUPPLY_MORPHO != address(0) && SUPPLY_AAVE != address(0), "set fuse instances");
        require(BAL_MORPHO != address(0) && BAL_AAVE != address(0), "set balance fuses");
        // roles (Alpha/Guardian/Atomist) are granted by the IPOR wizard — see step 10.

        vm.startBroadcast();

        // DEPLOY PATH: if the IPOR wizard performed clone() already, skip step 1 and load f from the
        //   wizard's output (plasmaVault/accessManager/feeManager/withdrawManager/priceManager), then
        //   run steps 2-9 from a role-holding account. Step 1 below is for the script-only deploy path.
        // 1) Deploy full Fusion instance (owner set at clone; DAO fee package chosen here)
        FusionFactoryLogicLib.FusionInstance memory f = FusionFactory(FUSION_FACTORY).clone(
            NAME, SYMBOL, USDC, REDEMPTION_DELAY, OWNER_SAFE, DAO_FEE_PACKAGE_INDEX
        );
        IPlasmaVaultGovernance vault = IPlasmaVaultGovernance(f.plasmaVault);
        console2.log("plasmaVault", f.plasmaVault);
        console2.log("accessManager", f.accessManager);
        console2.log("withdrawManager", f.withdrawManager);
        console2.log("feeManager", f.feeManager);

        // 2) Register supply fuses + balance fuses (Morpho 14, Aave 1)
        address[] memory fuses = new address[](2);
        fuses[0]=SUPPLY_MORPHO; fuses[1]=SUPPLY_AAVE;
        vault.addFuses(fuses);
        vault.addBalanceFuse(MID_MORPHO, BAL_MORPHO);
        vault.addBalanceFuse(MID_AAVE,   BAL_AAVE);
        // (No market-7 balance fuse: idle USDC is the underlying, counted natively in NAV.)

        // 3) Substrates. Morpho(14) = the 6 cb market ids; Aave(1) venue = USDC as bytes32.
        bytes32[] memory morphoSubs = new bytes32[](6);
        morphoSubs[0]=M_CBBTC; morphoSubs[1]=M_CBETH; morphoSubs[2]=M_CBXRP;
        morphoSubs[3]=M_CBDOGE; morphoSubs[4]=M_CBADA; morphoSubs[5]=M_CBLTC;
        vault.grantMarketSubstrates(MID_MORPHO, morphoSubs);
        vault.grantMarketSubstrates(MID_AAVE, _one(_a2b(USDC)));

        // 4) Dependency balance graph: NONE. Plain supply positions have no cross-market
        //    balance dependency, and market-7 (idle) is not tracked. (If a future leg leaves
        //    a non-underlying residual ERC20, add market-7 + map that leg -> [7] here.)

        // 5) On-chain AGGREGATE caps (1e18 = 100%). Per-cb caps are Alpha policy (see header).
        MarketLimit[] memory lim = new MarketLimit[](2);
        lim[0]=MarketLimit(MID_MORPHO, 0.80e18);
        lim[1]=MarketLimit(MID_AAVE,   0.25e18);
        vault.setupMarketsLimits(lim);
        // CONFIRM whether protection needs explicit activation (e.g. activateMarketsLimits()).

        // 6) Price oracle middleware (add USDC/USD + cb-collateral feeds in priceManager first)
        vault.setPriceOracleMiddleware(f.priceManager);

        // 7) Instant-withdraw waterfall: idle(auto) -> Aave -> Morpho:cbBTC -> Morpho:cbETH
        //    (Tier2/3 cb markets intentionally excluded from the instant lane.)
        InstantWithdrawalFusesParamsStruct[] memory w = new InstantWithdrawalFusesParamsStruct[](3);
        w[0]=InstantWithdrawalFusesParamsStruct(SUPPLY_AAVE,   _p(AMT, _a2b(USDC)));
        w[1]=InstantWithdrawalFusesParamsStruct(SUPPLY_MORPHO, _p(AMT, M_CBBTC));
        w[2]=InstantWithdrawalFusesParamsStruct(SUPPLY_MORPHO, _p(AMT, M_CBETH));
        vault.configureInstantWithdrawalFuses(w);
        // CONFIRM exact params[] layout per fuse against ipor-fusion docs.

        // 8) Scheduled-withdraw window (MANDATORY >0) on the WithdrawManager
        WithdrawManager(f.withdrawManager).updateWithdrawWindow(WITHDRAW_WINDOW);

        // 9) Fees — Bizantine recipient cut (DAO portion added via daoFeePackageIndex at clone)
        RecipientFee[] memory perf = new RecipientFee[](1); perf[0]=RecipientFee(FEE_RECIP, PERF_FEE);
        FeeManager(f.feeManager).updatePerformanceFee(perf);
        RecipientFee[] memory mgmt = new RecipientFee[](1); mgmt[0]=RecipientFee(FEE_RECIP, MGMT_FEE);
        FeeManager(f.feeManager).updateManagementFee(mgmt);

        // 10) Roles — HANDLED BY THE IPOR VAULT WIZARD (confirmed Noah 2026-07-07). Removed here
        //     to avoid double-granting. The wizard grants Owner, Atomist, Alpha (+Claim/Transfer
        //     rewards), Guardian, and instant-withdrawal-config. Reference:
        //       ATOMIST   = 0x81Bd70230a9D0928095364E3E72a900727e4Af6e (24h delay)
        //       ALPHA     = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6
        //       GUARDIAN  = 0x7420fE73F5c21D7d32E7a15B7eAAF7dB9ccad1Df
        //     IMPORTANT: steps 2-9 are role-restricted (FUSE_MANAGER/ATOMIST). Broadcast this script
        //     from the account the wizard granted those roles to, or perform the config in the wizard UI.
        //     (To grant roles from this script instead, restore the am.grantRole(...) calls from git.)

        vm.stopBroadcast();
        console2.log("DONE. Run VERIFY.md before seeding TVL / opening.");
    }

    // helpers
    function _one(bytes32 x) internal pure returns (bytes32[] memory a){ a=new bytes32[](1); a[0]=x; }
    function _p(bytes32 amt, bytes32 sub) internal pure returns (bytes32[] memory a){ a=new bytes32[](2); a[0]=amt; a[1]=sub; }
    function _a2b(address x) internal pure returns (bytes32){ return bytes32(uint256(uint160(x))); }
}
