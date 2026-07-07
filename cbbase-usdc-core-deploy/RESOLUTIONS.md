# RESOLUTIONS — outstanding deployment items (worked 2026-07-07)

Result of researching the real ipor-fusion repo + on-chain Base state. Split into
**resolved by me**, **recommended defaults**, and **genuine external dependencies**.

## 1. Per-market fuse instances + marketId architecture  → RESOLVED (design corrected)
The earlier scaffold used invented marketIds (Morpho 1–6, Compound 10, Aave 11). The **real**
IPOR registry (`contracts/libraries/IporFusionMarkets.sol`) is:
- **`MORPHO = 14`** — a *single* market. The `MorphoBalanceFuse` iterates **all** configured
  Morpho markets under id 14 and returns the **sum**. All 6 cb markets are **substrates** under one id.
- **`AAVE_V3 = 1`**, **`COMPOUND_V3_USDC = 2`**, **`ERC20_VAULT_BALANCE (idle) = 7`**.

So you need **3 supply fuses + 4 balance fuses**, not 6 Morpho instances:
`MorphoSupply(14)`, `MorphoBalance(14)`, `AaveV3Supply(1)`, `AaveV3Balance(1)`,
`CompoundV3Supply(2)`, `CompoundV3Balance(2)`, `Erc20Balance(7)`. These are **canonical shared
instances** IPOR has already deployed on Base and reuses across vaults — so this is "get 7 addresses
from Pavel," not "deploy 6 custom contracts."

**Consequence you must accept or override:** Fusion market limits are per-marketId. Under the canonical
single-Morpho model, **only aggregate caps are on-chain** — Morpho ≤80%, Aave ≤25%, Compound ≤20%.
The per-cb caps (cbBTC 50%, cbXRP 22%, cbDOGE 8%, …) and the tier buckets are **Alpha policy +
Hypernative, not the contract.** On-chain, the Alpha could legally put up to 80% in a single cb market.

- **Option B (default, in the script):** canonical single-Morpho. Simple, matches IPOR convention,
  fewest instances to audit. Per-cb caps live in Alpha policy (same place the tier caps already live).
- **Option A (on-chain per-cb caps):** ask IPOR to deploy **custom-marketId** Morpho supply+balance
  instances (one per cb market, non-canonical ids), then `setupMarketsLimits` per cb. True on-chain
  enforcement of the tight Tier3 caps — at the cost of 6 extra fuse instances + custom deployment.
  **Recommendation:** launch on B; if the institutional risk mandate requires on-chain enforcement of
  the thin Tier3 caps (cbDOGE/ADA/LTC), request A for those three specifically.

## 2. IPOR Alpha account  → RESOLVED
Address from the IPOR vault wizard: **`0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6`** (EIP-55 valid).
Holds `ALPHA_ROLE(200)` + `CLAIM_REWARDS(600)` + `TRANSFER_REWARDS(700)` — and nothing else (verify it
can't touch config: negative test in VERIFY.md). Filled into the script + config.

## 3. Hypernative guardian  → RESOLVED
Address: **`0x7420fE73F5c21D7d32E7a15B7eAAF7dB9ccad1Df`** (EIP-55 valid). Holds `GUARDIAN_ROLE(2)` only
(pause). Must act independently of the Alpha key (VERIFY.md dry-run). Filled into the script + config.

## 4. daoFeePackageIndex + DAO split  → RESOLVED (index read at deploy)
IPOR docs confirm the DAO fee is fixed: **0.3% base management (of TVL) + 2% *of* the performance fee**.
With a 10% perf fee that's 2% × 10% = **0.2% of profit to the DAO, 9.8% to Bizantine**; plus 0.3% mgmt to DAO.
`clone(..., daoFeePackageIndex)` selects the pre-registered package encoding this — read
`FusionFactory.getDaoFeePackagesLength()` + `getDaoFeePackage(i)` on Base at deploy and pick the standard
0.3%/2% package (commonly index 0). **One thing to confirm with Pavel:** whether Bizantine's 10% perf /
0.5% mgmt are charged *additive to* or *inclusive of* the DAO portion.

## 5. Withdraw-window duration  → RESOLVED (recommendation + setter)
Two distinct knobs:
- **Redemption delay** = `redemptionDelayInSeconds` at `clone()` → set **3600s (1h)** (anti-sandwich).
- **Scheduled-withdraw window** = `WithdrawManager.updateWithdrawWindow(seconds)` [ATOMIST]. Flow:
  user `requestShares` → Alpha `releaseFunds` → user withdraws within the window. **Recommend 48h
  (172800s)** to give the Alpha room to unwind the illiquid Tier2/3 tail. Factory default is readable via
  `FusionFactory.getWithdrawWindowInSeconds()` if you'd rather inherit it.

## 6. Owner/Atomist Safes controllable on Base  → RESOLVED (verified on-chain)
Checked all three addresses on **both** Ethereum mainnet and Base:
| Account | ETH mainnet | Base | Meaning |
|---|---|---|---|
| Owner `0x3FCA…1474` | EOA, nonce 1 | EOA, no code | Fordefi MPC EOA |
| Atomist `0x81Bd…Af6e` | EOA, nonce 78 (active) | EOA, no code, nonce 0 | Fordefi MPC EOA |
| Fee recip `0xB52e…D723` | EOA | EOA | EOA |

They are **EOAs (Fordefi MPC), not Safe contracts** — so there is **no Safe to deploy on Base**; the
same addresses are valid on Base natively. The only remaining step is **operational**: in Fordefi,
confirm Base (8453) is enabled for the Owner + Atomist MPC wallets, and send one tiny test tx from each
on Base before deploy (Atomist has never transacted on Base — nonce 0).

---
## 7. On-chain resolution of factory + fuses + Aave provider  → RESOLVED & VERIFIED (2026-07-07)

Source: IPOR `ipor-abi` registry `mainnet/mainnet-base-fusion/addresses.json`, each address then
verified on Base via `eth_call` (immutable getters). Method + raw reads in `ONCHAIN_VERIFICATION.md`.

| role | address | on-chain check |
|---|---|---|
| FusionFactory (IporFusionFactoryProxy) | `0x1455717668fA96534f675856347A973fA907e922` | 3 DAO fee pkgs; default window 86400 |
| SupplyFuseMorpho (14) | `0xae93EF3cf337b9599F0dfC12520c3C281637410F` | `MARKET_ID()=14`, `MORPHO()=0xBBBB…FFCb` |
| BalanceFuseMorpho (14) | `0x7916856E11E0CA021967D0D4daC49D737b7d73d5` | `MARKET_ID()=14` |
| SupplyFuseAaveV3 (1) | `0x26fD6EF391E98C78CfCA27e00c3d15be4D941625` | `MARKET_ID()=1`, `PROVIDER()=0xe20f…d64D` |
| BalanceFuseAaveV3 (1) | `0xf53f3EaFfDf67539256365cA7299540A98b60BA9` | `MARKET_ID()=1` |
| AaveV3PoolAddressesProvider | `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D` | `getPool()=0xA238…d1c5` (real Aave V3 Base pool) |

All filled into the script + config.

### Gap A — Compound V3 USDC fuse (marketId 2) does NOT exist on Base
Registry has only `SupplyFuseCompoundV3WEth 0xD72Dd19C04362488a4143F43e407ec87A849b72b`
(verified `MARKET_ID()=26`, `COMPOUND_BASE_TOKEN()=WETH 0x4200…0006`) — the WETH comet, not USDC.
**DECISION:** (a) ask IPOR to deploy `CompoundV3SupplyFuse(2)`+`CompoundV3BalanceFuse(2)` for the Base
USDC comet `0xb125E6687d4313864e53df431d5425969c15Eb2F`, or (b) keep the leg dropped and reallocate the
former 7% target (e.g. Aave 15%→22%, under the 25% cap) in Alpha policy. Script currently ships **(b)**.

### Gap B — Erc20 idle balance fuse (marketId 7) is NOT needed
`Erc20BalanceFuse` explicitly excludes the vault's underlying, and there is no `BalanceFuseErc20`
in the Base registry. Idle USDC (the underlying) is counted natively in NAV. IPOR's "add for each
vault" guidance is for vaults holding NON-underlying ERC20s (their example uses USDT on a USDC vault).
Removed from the script. **CONFIRM with Pavel** only if you later add a leg that leaves a foreign residual.

### daoFeePackageIndex — read on-chain
`getDaoFeePackage(i)` → `[0]` 0.05%/10% · **`[1]` 0.30%/2% (standard, SELECTED)** · `[2]` 0.50%/0%,
recipient = IPOR DAO `0xf6a9…5569`. LP-facing total is **curator + DAO** (see fee note in the script):
with pkg[1] and Bizantine 10%/0.5%, LPs pay **12% perf / 0.8% mgmt**. To cap LP total at 10%/0.5%,
set recipient fees to 800/20.

## Still needed before broadcast (external)

1. **DECISION — Compound USDC leg:** request IPOR fuses (mkt 2) or keep dropped (Gap A).
2. **DECISION — fee split:** Bizantine 10%/0.5% cut (LP pays 12%/0.8%) or cap LP total at 10%/0.5% (set 800/20).
3. **CONFIRM w/ Pavel:** daoFeePackageIndex entitlement; whether the vault wizard already grants roles
   (if so, delete script step 10 to avoid double-grant); markets-limits activation call; instant-withdraw
   `params[]` layout per fuse.
4. **Wizard fix:** change Owner/Atomist/FuseManager/PriceOracleMiddlewareManager from the IPOR default
   `0xF6a9…5569` (that address is IPOR's own infra owner) to your Fordefi addresses before finalizing.
5. **Fordefi:** enable Base for the Owner + Atomist MPC wallets; send a test tx from the Atomist (nonce 0 on Base).
6. **Build/sim:** fresh burner via `cast wallet import` → `forge build` → fork-sim clean pass →
   `forge script --broadcast --verify` → run `VERIFY.md` (incl. negative tests) → seed anchor TVL → open.


## 8. Final decisions (Noah 2026-07-07)

1. **Compound leg:** DROPPED (final). No Compound V3 USDC fuse on Base; former 7% reallocated in Alpha policy.
2. **Fees:** Bizantine **0% management / 10% performance**, charged ON TOP of the IPOR DAO package.
   With `daoFeePackageIndex=1` (0.30%/2%), LP-facing total = **12% perf / 0.3% mgmt**. Script: `PERF_FEE=1000`, `MGMT_FEE=0`.
3. **Roles:** the IPOR vault wizard grants roles → script **step 10 removed**. Broadcast steps 2–9 from the
   account the wizard granted `FUSE_MANAGER`/`ATOMIST` to, or do that config in the wizard UI.
4. **Owner:** `0x327d70c3E11CD26f3f11295459e6f4fbB6071474` (Fordefi; EIP-55 valid). Set this as Owner in the
   wizard (and Atomist/FuseManager/PriceOracleMiddlewareManager as intended) — NOT the IPOR default `0xF6a9…5569`.
5. **Fordefi Base enablement:** confirmed done.
