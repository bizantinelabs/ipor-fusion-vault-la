# Claude Code — Deployment Brief: Bizantine cbBase USDC CORE (IPOR Fusion, Base)

You are deploying an **IPOR Fusion Plasma Vault** for Bizantine Labs. Bizantine is the
**curator / Atomist**; **IPOR (Pavel)** provides Fusion infra + operates the Alpha service;
**Hypernative** is the Guardian. Read this whole brief before writing or running anything.

- **Product:** Bizantine cbBase USDC CORE  ·  **Symbol:** `bizcbBaseUSDC`  ·  **Asset:** USDC (Base, 6dp)
- **Chain:** Base (8453)  ·  **Framework:** IPOR Fusion (`FusionFactory.clone`)  ·  **Spec:** v0.7
- **Strategy:** USDC lending vault supplying Coinbase-Borrow-driven demand across cb-wrapped
  collateral Morpho markets (cbBTC/cbETH/cbXRP/cbDOGE/cbADA/cbLTC) + an Aave V3 venue leg. (Compound III USDC leg is deferred — no canonical fuse on Base yet; see RESOLUTIONS.md Gap A.)
- **This folder:** `config/cbbase_usdc_core.json` (all params), `script/DeployCbBaseUsdcCore.s.sol`
  (Foundry scaffold, grounded in real ipor-fusion interfaces), `RESOLUTIONS.md` (READ THIS — resolves the
  open items + records the canonical marketId model), `VERIFY.md`, `.env.example`.

## 0. PRE-FLIGHT GATE — do not broadcast until ALL are true
1. All protocol addresses (FusionFactory, Morpho supply+balance, Aave supply+balance, Aave provider) are FILLED and VERIFIED ON-CHAIN (2026-07-07; see ONCHAIN_VERIFICATION.md). Remaining open items are DECISIONS, not addresses (see RESOLUTIONS.md "Still needed").
2. Owner Safe / Atomist / Fee recipient confirmed **live and controllable on Base** (they were provided as `eth:` addresses — Safe/Fordefi must exist at the same address on Base, or record Base equivalents).
3. IPOR Alpha service account + Hypernative guardian account received.
4. `daoFeePackageIndex` + how the 10% perf / Biz–IPOR split maps to (package + FeeManager recipient) confirmed with Pavel.
5. Name/symbol final — **immutable after clone()**. Get `Bizantine cbBase USDC CORE` / `bizcbBaseUSDC` exactly right.

## 1. Setup
- Clone `https://github.com/IPOR-Labs/ipor-fusion` and work inside it (or add as a Foundry dep). Copy this
  folder's `script/` + `config/` in. `forge install`, ensure `solc 0.8.26`.
- **Verify every import in the script resolves** against the cloned repo. If a path/symbol differs from the
  scaffold, fix it against the real repo — do NOT invent symbols. Key real symbols already confirmed present:
  - `contracts/factory/FusionFactory.sol` → `clone(assetName, assetSymbol, underlyingToken, redemptionDelayInSeconds, owner, daoFeePackageIndex)` returns `FusionFactoryLogicLib.FusionInstance` (has `.plasmaVault .accessManager .feeManager .rewardsManager .withdrawManager .priceManager`).
  - `contracts/vaults/PlasmaVaultGovernance.sol` (iface `IPlasmaVaultGovernance`): `addFuses(address[])`, `addBalanceFuse(uint256,address)`, `grantMarketSubstrates(uint256,bytes32[])`, `setupMarketsLimits(MarketLimit[])`, `configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[])`, `setPriceOracleMiddleware(address)`, `convertToPublicVault()`.
  - `MarketLimit{ uint256 marketId; uint256 limitInPercentage }` (1e18 = 100%) in `AssetDistributionProtectionLib.sol`.
  - `InstantWithdrawalFusesParamsStruct{ address fuse; bytes32[] params }` (`params[0]`=amount at runtime; `params[1+]`=asset/marketId) in `PlasmaVaultLib.sol`.
  - `IporFusionAccessManager.grantRole(uint64 roleId, address account, uint32 executionDelay)`.
  - `Roles.sol`: OWNER=1, GUARDIAN=2, IPOR_DAO=4, ATOMIST=100, ALPHA=200, FUSE_MANAGER=300, CLAIM_REWARDS=600, TRANSFER_REWARDS=700, WHITELIST=800, CONFIG_INSTANT_WITHDRAWAL_FUSES=900, PRICE_ORACLE_MIDDLEWARE_MANAGER=1200.
  - `FeeManager.updatePerformanceFee(RecipientFee[])` / `updateManagementFee(RecipientFee[])`; `RecipientFee{ address recipient; uint256 feeValue }`.
  - Fuse constructors: `MorphoSupplyFuse(uint256 marketId, address morpho)`, `CompoundV3SupplyFuse(uint256 marketId, ...)`, `AaveV3SupplyFuse(uint256 marketId, address aaveV3PoolAddressesProvider)`. **Supply-fuse marketId is immutable.**

## 2. Architecture — CANONICAL marketId model (already resolved; see RESOLUTIONS.md §1)
IPOR's registry (`contracts/libraries/IporFusionMarkets.sol`) is authoritative:
`MORPHO = 14` (single market; all 6 cb markets are **substrates** under it, balance summed),
`AAVE_V3 = 1`, `MORPHO = 14`. `COMPOUND_V3_USDC = 2` exists in the lib but has NO fuse on Base (leg disabled). `ERC20_VAULT_BALANCE = 7` is not used (idle USDC is the underlying, counted natively).
The script uses these. You need **7 canonical shared fuse instances** from Pavel (Morpho supply+balance,
Launch config = Morpho(14) + Aave(1) supply+balance fuses — shared canonical instances, not 6 custom Morpho instances.
- If Noah has chosen **Option A** (on-chain per-cb caps), Pavel must instead provide custom-marketId Morpho
  instances (one per cb market) and you split `grantMarketSubstrates` + `setupMarketsLimits` per cb. Confirm
  which option before building. Default = canonical (Option B).

## 3. What is / isn't enforced on-chain (canonical model)
- **On-chain:** aggregate per-protocol caps — Morpho(14) ≤80%, Aave(1) ≤25%; substrate
  allowlist; NO dependency balance graph (plain supply, no cross-market deps); roles + timelock; fees; redemption delay;
  instant-withdraw order; scheduled-withdraw window.
- **NOT on-chain (Alpha policy + Hypernative):** per-cb caps (cbBTC 50%, cbXRP 22%, …), tier buckets
  (T2+3 ≤45%, T3 ≤15%), idle ≥5%. State this explicitly in your summary — on-chain, the Alpha could put up
  to 80% in a single cb market; the per-cb limits are policy, not contract (unless Option A was chosen).

## 4. Authorization ordering (get this right or the config calls revert)
`clone()` sets `owner_` = Owner Safe. Steps 2–7 of the script are `restricted` governance calls. Decide, against
the repo's initializer (`IporFusionAccessManagerInitializerLibV1`), **which account is authorized to run the
config calls at deploy time** and whether the ATOMIST timelock (`executionDelay`) makes them time-locked.
Recommended: run all config (fuses/substrates/limits/oracle/withdraw/fees) **as the Owner/deployer with delay 0**,
THEN grant the timelocked ATOMIST_ROLE last. Confirm and reorder `run()` if needed.

## 5. Build & dry-run
1. The scaffold is already filled + on-chain-verified. Do NOT change the locked constants or verified addresses. Resolve only the two DECISIONS (Compound leg; fee split) with Noah before broadcast.
2. `forge build` — resolve every compile error against the real repo (fix imports/signatures, never stub).
3. **Fork-simulate** against Base: `forge script script/DeployCbBaseUsdcCore.s.sol --rpc-url $BASE_RPC_URL --fork-url $BASE_RPC_URL -vvvv` (no `--broadcast`). Confirm the whole sequence succeeds on a fork.
4. Re-pull live substrate data same-day (rates/liquidity move): Morpho Blue API for the 6 market ids + DefiLlama for Aave. Confirm each Tier2/3 market's available liquidity >= 3x its target position; if not, flag before allowlisting.

## 6. Broadcast (only after §0 + fork sim pass)
`forge script script/DeployCbBaseUsdcCore.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify -vvvv`
Capture every deployed address (plasmaVault, accessManager, feeManager, rewardsManager, withdrawManager, priceManager) into `config/` and back into the spec §13.

## 7. Post-deploy — run VERIFY.md
Do not seed TVL or open the vault until every check in `VERIFY.md` passes, including the **negative tests**
(Alpha cannot change fuses/substrates/caps/fees/roles; Alpha cannot withdraw externally) and the **Guardian
dry-run** (pause → force-exit-to-buffer → unpause, independent of the Alpha key). Set the **mandatory scheduled
withdrawal window (>0)** on the WithdrawManager. Open via `convertToPublicVault()` (or keep whitelisted) per the
final deposits decision.

## Guardrails
- Never hardcode or broadcast a private key. Use `--account`/keystore or `$DEPLOYER_PK` env only for sim.
- Never invent an address, ABI, or role id. If unknown → stop and ask Pavel; leave the slot `address(0)`.
- Name/symbol/asset are immutable post-clone — triple-check before step 6.
- If anything in the repo contradicts this brief, the **repo wins** — tell the user what differs.
