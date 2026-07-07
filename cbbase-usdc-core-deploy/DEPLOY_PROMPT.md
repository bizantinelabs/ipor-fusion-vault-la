# Claude Code — Deployment Brief: Bizantine cbBase USDC CORE (IPOR Fusion, Base)

You are deploying an **IPOR Fusion Plasma Vault** for Bizantine Labs. Bizantine is the
**curator / Atomist**; **IPOR (Pavel)** provides Fusion infra + operates the Alpha service;
**Hypernative** is the Guardian. Read this whole brief before writing or running anything.

- **Product:** Bizantine cbBase USDC CORE  ·  **Symbol:** `bizcbBaseUSDC`  ·  **Asset:** USDC (Base, 6dp)
- **Chain:** Base (8453)  ·  **Framework:** IPOR Fusion (`FusionFactory.clone`)  ·  **Spec:** v0.7
- **Strategy:** USDC lending vault supplying Coinbase-Borrow-driven demand across cb-wrapped
  collateral Morpho markets (cbBTC/cbETH/cbXRP/cbDOGE/cbADA/cbLTC) + Compound III + Aave V3 venue legs.
- **This folder:** `config/cbbase_usdc_core.json` (all params), `script/DeployCbBaseUsdcCore.s.sol`
  (Foundry scaffold, grounded in real ipor-fusion interfaces), `VERIFY.md`, `.env.example`.

## 0. PRE-FLIGHT GATE — do not broadcast until ALL are true
1. Every `address(0)` / `CONFIRM_WITH_PAVEL` slot in the script + config is filled with a real Base address.
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

## 2. THE KEY ARCHITECTURE DECISION (resolve with Pavel first)
Per-market caps (cbBTC 50%, cbETH 25%, cbXRP 22%, cbDOGE 8%, cbADA 6%, cbLTC 5%) require a **distinct Fusion
`marketId` per cb market** (ids 1–6), because Fusion caps are per-marketId and a supply fuse's marketId is
immutable. That means **one MorphoSupplyFuse + one MorphoBalanceFuse instance per marketId**.
- **Option A (default, in the scaffold):** IPOR provides/deploys per-marketId fuse instances (ids 1–6 Morpho,
  10 Compound, 11 Aave). Full per-market caps enforced on-chain. ← preferred.
- **Option B (fallback):** single Morpho marketId for all 6 markets → only an **aggregate** Morpho cap on-chain
  (set 73–80%); per-cb caps then become Alpha-policy-only. Use only if IPOR won't provide per-market instances.
Ask Pavel which, and adjust the script accordingly.

## 3. IMPORTANT: what is and isn't enforced on-chain
- **On-chain:** per-marketId caps (§4 of the script), substrate allowlist, roles + timelock, fees, redemption delay, instant-withdraw ordering.
- **NOT on-chain (Alpha policy + Hypernative only):** aggregate Morpho ≤80%, Tier2+3 ≤45%, Tier3 ≤15%, idle ≥5%.
  Fusion market limits are independent per-market ceilings; their sum can exceed 100%. State this to the user in
  your summary — the aggregate caps in the spec live in IPOR's Alpha policy, not the contract.

## 4. Authorization ordering (get this right or the config calls revert)
`clone()` sets `owner_` = Owner Safe. Steps 2–7 of the script are `restricted` governance calls. Decide, against
the repo's initializer (`IporFusionAccessManagerInitializerLibV1`), **which account is authorized to run the
config calls at deploy time** and whether the ATOMIST timelock (`executionDelay`) makes them time-locked.
Recommended: run all config (fuses/substrates/limits/oracle/withdraw/fees) **as the Owner/deployer with delay 0**,
THEN grant the timelocked ATOMIST_ROLE last. Confirm and reorder `run()` if needed.

## 5. Build & dry-run
1. Fill the scaffold from `config/cbbase_usdc_core.json`. Keep the locked constants; fill the `address(0)` slots.
2. `forge build` — resolve every compile error against the real repo (fix imports/signatures, never stub).
3. **Fork-simulate** against Base: `forge script script/DeployCbBaseUsdcCore.s.sol --rpc-url $BASE_RPC_URL --fork-url $BASE_RPC_URL -vvvv` (no `--broadcast`). Confirm the whole sequence succeeds on a fork.
4. Re-pull live substrate data same-day (rates/liquidity move): Morpho Blue API for the 6 market ids + DefiLlama for Compound/Aave. Confirm each Tier2/3 market's available liquidity ≥ 3× its target position; if not, flag before allowlisting.

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
