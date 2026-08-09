// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////////////////
    bzFXRP-ETH — CONFIG-ONLY draft script. DO NOT BROADCAST.

    This is NOT a full deployment script. It covers only what is genuinely just configuration
    against the EXISTING shell (0x8c0127f303d1173229c4bf708b8619909b06a83e), using addresses
    and constants verified on-chain / against the real IPOR-Labs/ipor-fusion repo (see
    FINDINGS.md for the verification trail). Explicitly EXCLUDED, because the underlying pieces
    do not exist yet:

      - FXRPPriceFeedEthereum is not deployed (needs a real broadcast + governance decision on
        TWAP_WINDOW/MAX_STALENESS/MAX_DISCOUNT_BPS — none of which are set here).
      - AguaSupplyFuse / AguaBalanceFuse are not deployed (this package drafts them; they are
        UNAUDITED and untested against Agua's real interface — see FINDINGS.md §5).
      - No ERC4626 fuse instance exists for Euler eUSDC-2 (FINDINGS.md §4) — must be requested
        from IPOR or freshly deployed before this reserve leg can be wired.
      - No LTV enforcement contract exists (FINDINGS.md §6 — this needs a custom Morpho borrow
        fuse wrapper, not a pre-hook; not written here).
      - WithdrawManager is not deployed.

    Running this script as-is would therefore whitelist Morpho/swapper fuses and register
    RLUSD/USDC prices with NO price for FXRP itself yet — i.e. it deliberately does NOT reach a
    depositable state. That is intentional: this covers the config steps that CAN be nailed down
    now, so the remaining steps (deploy custom contracts, request eUSDC-2 fuse, build LTV guard,
    deploy WithdrawManager) are the only things left before a real pre-flight gate check.

    Roles/addresses per the deployment package (NOT re-verified as "controllable on Base/mainnet"
    here — that is an operational Fordefi/Safe check, out of scope for this script):
      Governance Safe : 0x3FCA4624A7fc97301daffec96834939dE6671474
      Fordefi MPC      : 0x81Bd70230a9D0928095364E3E72a900727e4Af6e
      Hypernative      : 0x7420fE73F5c21D7d32E7a15B7eAAF7dB9ccad1Df
      Fee recipient    : 0x3D5341AE003BD0cCd05FD38273CC28832205f29E
//////////////////////////////////////////////////////////////////////////*/

import {Script, console2} from "forge-std/Script.sol";
import {IPlasmaVaultGovernance} from "contracts/interfaces/IPlasmaVaultGovernance.sol";
import {MarketLimit} from "contracts/libraries/AssetDistributionProtectionLib.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {Roles} from "contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";

contract ConfigureBzFxrpEth is Script {
    // ── existing shell (verified state 2026-08-09: name/symbol/asset match, totalAssets=0) ──
    address constant VAULT = 0x8C0127f303D1173229C4Bf708b8619909B06a83E;
    address constant ACCESS_MANAGER = 0x2BEc727280a2b27Baf751E27fF1444210501f2E2;
    address constant PRICE_ORACLE_MIDDLEWARE = 0xD64E53df810e191B0E7167c588ede07F0f4c7a69;

    // ── governance actors (per deployment package) ──
    address constant GOVERNANCE_SAFE = 0x3FCA4624A7fc97301daffec96834939dE6671474;
    address constant FORDEFI_MPC = 0x81Bd70230a9D0928095364E3E72a900727e4Af6e;
    address constant HYPERNATIVE = 0x7420fE73F5c21D7d32E7a15B7eAAF7dB9ccad1Df;
    address constant FEE_RECIPIENT = 0x3D5341AE003BD0cCd05FD38273CC28832205f29E;
    uint32 constant ATOMIST_DELAY = 86400; // 24h, per the deployment package's minimum

    // ── real, already-deployed shared fuse instances (read from live vaults via getFuses(),
    //    see FINDINGS.md §4 — NOT invented, NOT from the deployment package's prose) ──
    address constant MORPHO_FLASH_LOAN_FUSE = 0x9185033e24dB36407b9b1A1886Cb47B9533433DE; // MARKET_ID=19, confirmed
    address constant MORPHO_FUSE_A = 0xE1aA89eb42C23f292cDa1544566F6EBeE3a67EED; // MARKET_ID=14, role (Collateral/Borrow) UNCONFIRMED
    address constant MORPHO_FUSE_B = 0x9981e75b7254fD268C9182631Bf89C86101359d6; // MARKET_ID=14, role (Collateral/Borrow) UNCONFIRMED
    address constant MORPHO_BALANCE_FUSE = 0xD08Cb606CEe700628E55b0B0159Ad65421E6c8Df; // MARKET_ID=14, likely balance fuse (bytecode size) — UNCONFIRMED
    address constant UNIVERSAL_SWAPPER_FUSE = 0x08dFdBB6Ecf19f1fc974E0675783E1150B2B650F; // MARKET_ID=12, confirmed

    // ── real Chainlink feeds (already deployed, independent of this vault) ──
    address constant CHAINLINK_RLUSD_USD = 0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A;
    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ── Morpho FXRP/RLUSD market substrate ──
    bytes32 constant M_FXRP_RLUSD = 0x4fa31e3f8ba345227d44e1cf48559eea53a90dd5311dc006984c060f2f311d96;

    function run() external {
        require(MORPHO_FUSE_A != MORPHO_FUSE_B, "sanity");
        console2.log("DRAFT config script - not intended to broadcast against a leveraged mainnet vault without governance sign-off");

        vm.startBroadcast();
        IPlasmaVaultGovernance vault = IPlasmaVaultGovernance(VAULT);
        IporFusionAccessManager am = IporFusionAccessManager(ACCESS_MANAGER);

        // 1) Roles. NOTE: does not grant/revoke any deployer temp role — this script assumes
        //    whoever broadcasts it already holds ATOMIST_ROLE/FUSE_MANAGER_ROLE (e.g. via the
        //    IPOR vault wizard, as observed in the earlier cbBase-USDC-CORE work) or is running
        //    this from the Governance Safe itself via a batched Safe transaction. CONFIRM which
        //    model applies before broadcasting — see the cbBase package's "deploy identity" note
        //    for the same ambiguity encountered there.
        am.grantRole(Roles.ATOMIST_ROLE, GOVERNANCE_SAFE, ATOMIST_DELAY);
        am.grantRole(Roles.ALPHA_ROLE, FORDEFI_MPC, 0);
        am.grantRole(Roles.GUARDIAN_ROLE, HYPERNATIVE, 0);
        am.grantRole(Roles.FUSE_MANAGER_ROLE, GOVERNANCE_SAFE, ATOMIST_DELAY);
        am.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, GOVERNANCE_SAFE, ATOMIST_DELAY);
        am.grantRole(Roles.WHITELIST_ROLE, GOVERNANCE_SAFE, ATOMIST_DELAY);
        am.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, GOVERNANCE_SAFE, ATOMIST_DELAY);
        // NOTE: does NOT grant OWNER_ROLE — confirm current owner (should already be
        // GOVERNANCE_SAFE from clone(); do not re-grant blindly, verify first).

        // 2) Price registration — RLUSD and USDC only. FXRP is deliberately NOT registered here;
        //    FXRPPriceFeedEthereum does not exist yet (see header). Registering RLUSD/USDC alone
        //    does not make the vault depositable — totalAssets() still cannot value FXRP.
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = RLUSD;
        sources[0] = CHAINLINK_RLUSD_USD;
        assets[1] = USDC;
        sources[1] = CHAINLINK_USDC_USD;
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, sources);

        // 3) Fuse whitelist — Morpho + Universal Swapper only. Deliberately EXCLUDES:
        //      - eUSDC-2 ERC4626 fuse (does not exist — FINDINGS.md §4)
        //      - Aave V3 fuses (deployment package's §6 lists Aave for reserve diversification;
        //        not included in this draft — add once the reserve-venue split is finalized)
        //      - AguaSupplyFuse/AguaBalanceFuse (drafted, not deployed, unaudited)
        //      - MerklClaimFuse (not located/verified in this pass)
        address[] memory fuses = new address[](4);
        fuses[0] = MORPHO_FUSE_A;
        fuses[1] = MORPHO_FUSE_B;
        fuses[2] = MORPHO_FLASH_LOAN_FUSE;
        fuses[3] = UNIVERSAL_SWAPPER_FUSE;
        vault.addFuses(fuses);
        vault.addBalanceFuse(IporFusionMarkets.MORPHO, MORPHO_BALANCE_FUSE);
        // No balance fuse added for market 7 (ERC20_VAULT_BALANCE) here — confirm whether this
        // vault needs it (bzFXRP-ETH's idle asset IS the underlying, same situation encountered
        // on the earlier cbBase vault where an idle-USDC balance fuse turned out to be
        // unnecessary because Erc20BalanceFuse excludes the vault's own underlying). Do not add
        // one reflexively; check first.

        // 4) Substrates.
        bytes32[] memory morphoSubstrates = new bytes32[](1);
        morphoSubstrates[0] = M_FXRP_RLUSD;
        vault.grantMarketSubstrates(IporFusionMarkets.MORPHO, morphoSubstrates);
        vault.grantMarketSubstrates(IporFusionMarkets.MORPHO_FLASH_LOAN, morphoSubstrates);
        // Universal swapper substrates (named Curve pool + RLUSD/USDC token addresses) are NOT
        // set here — needs the exact UniversalTokenSwapperFuse substrate encoding confirmed
        // against its real ABI before granting, not assumed from the deployment package's prose.

        // 5) Market limits — placeholder values only. DO NOT use these numbers; they are not
        //    derived from the required Uniswap V3 depth measurement (still an open blocker).
        //    Included so the call shape is correct, with an explicit revert-your-attention marker.
        MarketLimit[] memory limits = new MarketLimit[](2);
        limits[0] = MarketLimit(IporFusionMarkets.MORPHO, 0); // PLACEHOLDER — do not broadcast at 0
        limits[1] = MarketLimit(IporFusionMarkets.MORPHO_FLASH_LOAN, 1e18); // flash loan is atomic; cap is not the binding constraint there
        vault.setupMarketsLimits(limits);
        // vault.activateMarketsLimits() deliberately NOT called — do not activate limits set to
        // a placeholder value.

        vm.stopBroadcast();
        console2.log("DONE (partial). Remaining: FXRP price feed, eUSDC-2 fuse, Agua fuses, LTV guard, WithdrawManager, real market limits from measured depth.");
    }
}
