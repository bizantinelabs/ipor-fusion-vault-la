# Repo verification & findings — Bizantine cbBase USDC CORE

Verified the scaffold against a fresh clone of **IPOR-Labs/ipor-fusion** (default branch,
`foundry.toml` pins **solc 0.8.30**) and verified on-chain data via the IPOR MCP server
(`mcp.ipor.io`, sourcing `ipor-abi`) + the Morpho Blue API. Date: 2026-07-07.

**Bottom line:** the scaffold's interfaces mostly line up, but it had **several bugs that
would have reverted the deploy or mis-set fees**. Those are fixed in the corrected
`script/DeployCbBaseUsdcCore.s.sol`. The deploy **cannot be broadcast** yet — the pre-flight
gate is still blocked on IPOR/Pavel-provided addresses (all 17 fuse instances, Alpha/Guardian
accounts, `daoFeePackageIndex` + DAO fee split). I did **not** broadcast and did **not** invent
any address.

---

## A. Interfaces confirmed against the real repo (no change needed)

| Symbol | Result |
|---|---|
| `FusionFactory.clone(name,symbol,underlying,redemptionDelay,owner,daoFeePackageIndex)` | ✅ exact match |
| `FusionInstance` fields (`.plasmaVault/.accessManager/.feeManager/.rewardsManager/.withdrawManager/.priceManager`) | ✅ all present (+`contextManager`,`plasmaVaultBase`) |
| `IPlasmaVaultGovernance`: `addFuses/addBalanceFuse/grantMarketSubstrates/setupMarketsLimits/configureInstantWithdrawalFuses/convertToPublicVault` | ✅ present |
| `MarketLimit{marketId,limitInPercentage}` (1e18=100%) | ✅ match |
| `InstantWithdrawalFusesParamsStruct{fuse,params}` (params[0]=amount at runtime) | ✅ match |
| `IporFusionAccessManager.grantRole(uint64,address,uint32)` | ✅ match |
| `FeeManager.updatePerformanceFee/updateManagementFee(RecipientFee[])`; `RecipientFee{recipient,feeValue}` | ✅ match |
| `Roles`: OWNER=1,GUARDIAN=2,IPOR_DAO=4,ATOMIST=100,ALPHA=200,FUSE_MANAGER=300,CLAIM=600,TRANSFER=700,WHITELIST=800,CONFIG_INSTANT=900,PRICE_ORACLE_MW=1200 | ✅ match |
| Fuse ctors: `MorphoSupplyFuse(marketId,morpho)`, `MorphoBalanceFuse(marketId,morpho)`, `CompoundV3SupplyFuse(marketId,comet)`, `AaveV3SupplyFuse(marketId,poolAddressesProvider)` | ✅ match |

## B. Bugs found & fixed in the corrected script

| # | Severity | Finding (scaffold → repo truth) | Fix |
|---|---|---|---|
| 1 | **Critical** | **Config calls would all revert.** `clone(owner_)` grants **only OWNER_ROLE** to `owner_` (verified in `FusionFactoryLogicLib` + `IporFusionAccessManagerInitializerLibV1`). Nobody holds ATOMIST/FUSE_MANAGER/CONFIG_INSTANT/PRICE_MW. But steps 2–7 call functions gated to those roles, and the scaffold granted roles only in step 8 (after) — and never granted FUSE_MANAGER or CONFIG_INSTANT at all. | Reordered: clone with `owner_=deployer`; deployer grants itself the temp roles (owner→ATOMIST→FUSE_MANAGER/CONFIG_INSTANT/PRICE_MW, delay 0); run config; then grant production roles + hand OWNER to the Safe + **revoke deployer temp roles**. Matches `test/TestConfigurationExample.t.sol`. |
| 2 | **Critical** | **Fee scale wrong.** FeeManager uses **2-decimal percent** (100 = 1%, 1000 = 10%), not 1e18. Scaffold passed `0.10e18`/`0.005e18` → astronomically large fee values. Also **total fee = DAO fee + Σ recipient fees**, so Bizantine's slice must be `spec_total − DAO_portion`. | Fees now `SPEC_TOTAL_PERF=1000`, `SPEC_TOTAL_MGMT=50`, minus `DAO_PERF_FEE`/`DAO_MGMT_FEE` (sentinel-guarded until Pavel confirms). |
| 3 | **Critical** | **Caps never enforced.** `setupMarketsLimits` sets limits but a separate `activateMarketsLimits()` (ATOMIST) is required to turn protection on. Scaffold left this as a TODO comment. | Added `vault.activateMarketsLimits();`. |
| 4 | **High** | **Wrong price-oracle call.** Scaffold did `vault.setPriceOracleMiddleware(f.priceManager)`. The factory already wires the vault to the shared `PriceOracleMiddleware` at clone (via `priceManager`); `priceManager` is the *manager*, not a middleware. | Removed. Optional USDC/USD source registration via `priceManager.setAssetsPriceSources(...)` only if VERIFY shows USDC unpriced. |
| 5 | **High** | **Missing idle-USDC accounting.** No balance fuse for `ERC20_VAULT_BALANCE` (verified `=7`). Without it the vault can't value idle USDC (breaks NAV + the "idle" withdrawal leg). Also needs a dependency graph so lending markets depend on market 7. | Added `addBalanceFuse(7, BAL_ERC20_IDLE)`, substrate for 7, and `updateDependencyBalanceGraphs(...)`. New `BAL_ERC20_IDLE` slot (address(0), CONFIRM). |
| 6 | **High** | **Mandatory withdrawal window not set.** VERIFY requires a scheduled window > 0; scaffold only left a comment. Real setter: `WithdrawManager.updateWithdrawWindow(uint256)` (ATOMIST). | Added the call, guarded by `require(WITHDRAW_WINDOW_SECONDS > 0)`. |
| 7 | Medium | **Deployer capture footgun.** `msg.sender` inside `run()` is forge's default sender, not the `--account` signer → would mis-set clone owner. | Use `(, address deployer,) = vm.readCallers();`. |
| 8 | Low | pragma `0.8.26` vs repo `solc 0.8.30`. The repo's `foundry.toml` **forces** `solc = "0.8.30"`, so the exact `pragma solidity 0.8.26;` does **not** compile inside the repo (compiler-version mismatch), contrary to the earlier "compatible" assumption. | **Fixed:** pragma bumped to `0.8.30` to match the repo. Confirmed by an actual `forge build` this session (see §F). |

## C. On-chain data verification

**Addresses (VERIFIED from `ipor-abi` mainnet-base-fusion, via mcp.ipor.io) — filled in the script/config:**
- FusionFactory (Base) = `0x1455717668fA96534f675856347A973fA907e922` (`IporFusionFactoryProxy`)
- Aave V3 PoolAddressesProvider (Base) = `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D`

**Morpho markets (VERIFIED via Morpho Blue API, chain 8453) — all six are USDC-loan with the expected collateral; substrate IDs in the config are correct:**

| id | market | loan | collateral | LLTV | supply APY | util | available liquidity |
|---|---|---|---|---|---|---|---|
| 1 | cbBTC/USDC | USDC ✅ | cbBTC | 86% | 4.15% | 88% | ~$167.4M |
| 2 | cbETH/USDC | USDC ✅ | cbETH | 86% | 4.15% | 88% | ~$0.59M |
| 3 | cbXRP/USDC | USDC ✅ | cbXRP | 62% | 5.55% | 88% | ~$4.05M |
| 4 | cbDOGE/USDC | USDC ✅ | cbDOGE | 62% | 5.55% | 88% | ~$0.24M |
| 5 | cbADA/USDC | USDC ✅ | cbADA | 62% | 5.51% | 88% | ~$0.19M |
| 6 | cbLTC/USDC | USDC ✅ | cbLTC | 62% | 5.49% | 88% | ~$0.09M |

**⚠️ §5.4 liquidity flag.** The small-cap legs are thin. Re-run same-day before allowlisting and
size positions so **available liquidity ≥ 3× target position**:
- cbLTC ~$86K, cbADA ~$190K, cbDOGE ~$242K available. At only ~$5M vault TVL the T3 targets
  (2–3%) already sit near or above the 3× threshold (e.g. cbLTC 2% of $5M = $100K > $86K available).
- cbETH available is only ~$0.59M yet it's a T1 leg **in the instant-withdraw waterfall** (cap 25%,
  target 14%). Thin instant-withdraw liquidity is worth flagging to IPOR/Hypernative.
- cbBTC (~$167M) and cbXRP (~$4M) are comfortable at expected TVL.

**Compound leg:** config Comet `0xb125E6687d4313864e53df431d5425969c15Eb2F` is the known Base
cUSDCv3, but **no CompoundV3-USDC supply/balance fuse is deployed in `ipor-abi` on Base** (only a
WETH-comet one). IPOR must deploy the USDC Compound fuses (id 10) — part of the blocked list below.

## D. Architecture note (Option A vs B) — unchanged, still needs Pavel

Per-market caps require a distinct Fusion `marketId` per cb market (1–6), and a supply fuse's
marketId is immutable ⇒ **one MorphoSupply + one MorphoBalance instance per marketId**. `ipor-abi`
ships only single shared instances (one `SupplyFuseMorpho`, one `BalanceFuseMorpho`), so **Option A
requires IPOR to deploy per-market instances**. Confirm A vs B with Pavel; the script implements A.

## E. On-chain vs off-chain caps (state in the deploy summary)

On-chain (enforced): per-market caps (after `activateMarketsLimits`), substrate allowlist,
roles+timelock, fees, redemption delay, instant-withdraw ordering, scheduled withdraw window.
**Not on-chain** (Alpha policy + Hypernative only): aggregate Morpho ≤80%, Tier2+3 ≤45%, Tier3 ≤15%,
idle ≥5%. The eight per-market ceilings sum to 161% — they are independent caps, not an allocation.

## F. Build & fork-sim actually executed (2026-07-07)

Foundry **1.7.1** was installed and the script was compiled and fork-simulated against a fresh
clone of `IPOR-Labs/ipor-fusion` (submodules + `npm install` for the `@openzeppelin`/`@uniswap`/
`@pendle`/EVC remappings). No broadcast, no address invented.

- `forge build script/DeployCbBaseUsdcCore.s.sol` → **compiles clean** (warnings only) after the
  §B#8 pragma bump to `0.8.30`. All imports/signatures resolve exactly as authored.
- `forge script …:DeployCbBaseUsdcCore --rpc-url <base>` (no `--broadcast`) → the script contract
  deploys, then `run()` **reverts at the first pre-flight guard: `set DAO_FEE_PACKAGE_INDEX`** —
  i.e. the gate correctly blocks the deploy while the `CONFIRM_WITH_PAVEL` sentinels are unset.
  This is the furthest the sim can go until IPOR/Pavel provide the blocked slots (§Pre-flight gate).

Reproduce:
```bash
git clone --depth 1 https://github.com/IPOR-Labs/ipor-fusion.git && cd ipor-fusion
git submodule update --init --recursive && npm install
cp -r ../cbbase-usdc-core-deploy/script ../cbbase-usdc-core-deploy/config .
forge build script/DeployCbBaseUsdcCore.s.sol
forge script script/DeployCbBaseUsdcCore.s.sol:DeployCbBaseUsdcCore --rpc-url "$BASE_RPC_URL" -vvvv
```

---

## Pre-flight gate (§0) status

| Gate item | Status |
|---|---|
| FusionFactory (Base) | ✅ filled (verified) |
| Aave V3 PoolAddressesProvider | ✅ filled (verified) |
| Morpho substrate IDs + USDC-loan | ✅ verified |
| Per-market fuse instances (Morpho 1–6, Compound 10, Aave 11) + idle balance fuse (7) | ❌ **BLOCKED — IPOR must deploy/provide** |
| IPOR Alpha service account | ❌ BLOCKED (CONFIRM_WITH_PAVEL) |
| Hypernative guardian account | ❌ BLOCKED (TBD) |
| `daoFeePackageIndex` + DAO perf/mgmt split | ❌ BLOCKED (CONFIRM_WITH_PAVEL) |
| Owner Safe / Atomist / Fee recipient controllable on Base | ⚠️ addresses present; **confirm Safe control on Base** |
| Deploy identity (deployer-as-temp-owner vs Safe-batched) | ⚠️ CONFIRM with Pavel |
| Scheduled withdraw window duration | ⚠️ CONFIRM duration (must be > 0) |
| ATOMIST timelock (24h vs 48h) | ⚠️ CONFIRM |
| Name/symbol/asset final | ✅ locked in script |

## Operator steps remaining (not doable in this session)

1. Fill the blocked slots above once IPOR provides them (all still `address(0)` / sentinel).
2. ~~`forge build` in a clone of ipor-fusion~~ — **DONE this session** (see §F): compiled clean
   against the real repo and fork-simulated on Base. Re-run when the blocked slots are filled.
3. Fork-simulate on Base (no `--broadcast`); confirm the full sequence passes.
4. Re-pull Morpho/DefiLlama liquidity same-day; enforce the ≥3× rule (see §C flag).
5. Broadcast only after §0 is all-green, then run `VERIFY.md` (incl. negative + Guardian tests).
