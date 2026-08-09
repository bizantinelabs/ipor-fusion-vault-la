# bzFXRP-ETH — independent verification findings (2026-08-09)

Everything below was checked live on Ethereum mainnet (via `cast`, public RPC) or against a
fresh clone of `IPOR-Labs/ipor-fusion` (Foundry 1.7.1, `forge build`). No transaction was sent,
no address was invented, no private key was used or is available in this environment.

## 0. Address correction — read this first

The link `https://app.ipor.io/fusion/ethereum/0xf8f226da66244f89e70c5b5d1a5c5b0d505eb1d8` shared to
mean "deploy into this vault" resolves to **`bdUSD` ("Bitcoin Dollar USDC")** — a live, unrelated,
already-funded vault (`totalAssets` ≈ 743,809 USDC, `totalSupply` ≈ 656,815 shares). It is not part
of the bzFXRP-ETH deployment. It only appears in the PDF once, as a *reference data point* for
confirming the `decimals()` offset convention. All work below targets the real bzFXRP-ETH shell,
**`0x8c0127f303d1173229c4bf708b8619909b06a83e`**. Nothing was configured or touched on `bdUSD`.

## 1. bzFXRP-ETH shell — current state (re-verified)

| Field | Value | Matches docs? |
|---|---|---|
| name / symbol | "Bizantine FXRP Carry Vault" / `bzFXRP-ETH` | Yes |
| asset / decimals | FXRP (6dp) / 8 | Yes |
| totalAssets / totalSupply | 0 / 0 | Yes |
| `getFuses()` | **`[0x79e8B115Bd41baee318c1940F42F1a2d94D29ab4]`** | **No — docs claim zero fuses** |
| FXRP price source | `0x0` (unset) | Yes (B1 confirmed) |
| RLUSD price source | `0x0` (unset) | Yes (B2 confirmed) |
| USDC price | ~0.9998 USD | Yes |

**The "zero fuses" claim in every document is stale.** One fuse is already registered. Its
`MARKET_ID()` returns `type(uint256).max` — a sentinel, not a real market — and the exact same
address (`0x79e8B115...ab4`) is also present on the Origin wOUSD Loop vault (`0xF373a4D4...`),
confirming it is a **factory-shared utility fuse** (most likely `BurnRequestFeeFuse`, which
`FusionFactory.initialize()` wires into every cloned vault), not a strategy fuse anyone configured.
Not a blocker, but the "zero fuses" premise should be corrected in the source documents.

## 2. Market ID correction

Both `bizFXRP-ETH_FULL_SPEC.md` (§7) and the PDF (§6) state: *"idle/ERC-20 = 19"*. This is **wrong**.
Read directly from `IPOR-Labs/ipor-fusion/contracts/libraries/IporFusionMarkets.sol`:

```
MORPHO_FLASH_LOAN      = 19   // NOT idle
ERC20_VAULT_BALANCE    = 7    // this is the real idle/ERC20 market
UNIVERSAL_TOKEN_SWAPPER = 12  // confirmed correct
MORPHO                 = 14   // confirmed correct
EULER_V2               = 11   // exists as an allocated market (not directly relevant here)
```

This is a fortunate coincidence, not a contradiction: the PDF's own fuse plan already includes
`MorphoFlashLoanFuse` for atomic lever/delever, and market 19 is exactly where that fuse belongs.
The mistake was labeling 19 as "idle" — the real idle/ERC20 market for tracking loose USDC/FXRP is
**7**, not 19. Configure idle substrates under market 7, not 19.

## 3. Morpho Blue address — now definitively confirmed, not "believed"

Read the `MORPHO()` immutable directly off three independently deployed fuse instances
(two on the Origin vault, one on bdUSD): all three return
**`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`**, matching the spec's address. This resolves
blocker "Morpho Blue address independently verified" — it's real and confirmed on-chain, not a
"believed"/"verify before use" placeholder anymore.

## 4. Real fuse addresses discovered (read from live vaults, not invented)

Queried `getFuses()` on the Origin wOUSD Loop (`0xF373a4D4...`) and `bdUSD` (`0xf8f226da...`), then
fingerprinted each returned address via its `MARKET_ID()` immutable:

| Address | `MARKET_ID()` | Likely role |
|---|---:|---|
| `0x9185033e24dB36407b9b1A1886Cb47B9533433DE` | 19 | `MorphoFlashLoanFuse` |
| `0xE1aA89eb42C23f292cDa1544566F6EBeE3a67EED` | 14 | Morpho functional fuse (Collateral or Borrow) |
| `0x9981e75b7254fD268C9182631Bf89C86101359d6` | 14 | Morpho functional fuse (Collateral or Borrow) |
| `0xD08Cb606CEe700628E55b0B0159Ad65421E6c8Df` | 14 | Likely `MorphoBalanceFuse` (13.1K bytecode vs ~8K for the other two — balance fuses carry more logic) |
| `0x08dFdBB6Ecf19f1fc974E0675783E1150B2B650F` | 12 | `UniversalTokenSwapperFuse` |
| `0x7b3957B38b1c91057755D71701247905b48D6063` | 1 | Aave V3 functional fuse |
| `0x820D879Ef89356B93A7c71ADDBf45c40a0dDE453` | 1 | Aave V3 balance fuse (or vice versa) |

**Not confirmed:** which of the two market-14 addresses is Collateral vs. Borrow (direct `cast call`
reverts on both — they expect delegatecall context from a vault, so this can't be resolved by a
plain read). Confirm against IPOR's fuse registry or their team before whitelisting either.

~~**Confirmed gap:** no shared ERC4626 fuse instance for eUSDC-2 exists yet; must be requested from
IPOR or freshly deployed.~~ — **RETRACTED, this was wrong. See §13.** The observation that neither
`bdUSD` ERC4626 instance (100001 → substrate `0x3bc80141...`, 100002 → substrate `0xa3931d71...`)
*currently* targets eUSDC-2 is accurate, but the conclusion drawn from it was not: substrates are
per-vault, so no new fuse deployment is required.

## 5. Agua interface — verified where possible, flagged where not

`0xa98b4a70e17e55045cde4972b95bc2e8cec22a0f` is **not verified on Sourcify** (no ABI available).
Direct on-chain calls to the *view* functions the PDF describes all returned sane, corroborating
values:

| Call | Result | PDF claim |
|---|---|---|
| `earlyRedemptionFee()` | 500 | "5% fee" — matches exactly (500bps) |
| `lockupPeriod()` | 432000 | "5-day wait" — matches exactly (432000s = 5.000 days) |
| `maxWithdraw()` / `maxRedeem()` | 0 / 0 | "not 4626-compliant on exit" — confirmed |
| `asset()` | real USDC address | matches |
| `decimals()` | 18 | matches ("18dp shares") |
| `cumulativeRateFactor()` | ~1.014e27 | consistent with a RAY-scaled (1e27) factor |

This strongly corroborates the PDF's description overall. However, the **state-changing**
functions (`deposit`, `requestRedemption`, `completeRedemption`, `redeemEarly`, `cancelRedemption`)
could not be independently verified — no verified source, no ABI. `AguaSupplyFuse.sol` (below) is
built against the PDF's stated signatures, with every such call explicitly flagged
`UNVERIFIED SIGNATURE` in-line. Confirm each against Agua's real contract before deployment.

## 6. Architectural finding: the "LTV pre-hook" as specced cannot be a generic pre-hook

Read `contracts/handlers/pre_hooks/{IPreHook.sol,PreHooksHandler.sol}` and the real
`ExchangeRateValidatorPreHook.sol` example directly. `PreHooksHandler._runPreHook` calls:

```solidity
implementation.functionDelegateCall(abi.encodeWithSelector(IPreHook.run.selector, selector_));
```

A hook receives **only the top-level function selector** (e.g. `execute(FuseAction[])`'s selector)
— never the actual `FuseAction[]` calldata about to run. It fires *before* any of the batched fuse
actions execute, once per `execute()` call, with no visibility into what those actions will do. Even
the most sophisticated real example in the repo only validates state that already exists (PPS via
`convertToAssets`) — there is no "post-hook that runs after the vault's fund movements" concept
anywhere in the real hook system; the "pre/post" naming inside `ExchangeRateValidatorPreHook`
refers to ordering *within* a single pre-execution call, not before/after the operation's effects.

**Consequence:** "custom LTV pre-hook... simulates the post-action position... reverts every
action that would exceed 40% LTV" — as literally specced — is not implementable this way. The
technically correct location for that check is inside a **custom `MorphoBorrowFuse` wrapper**,
since fuses (unlike pre-hooks) *do* receive the specific action data
(`MorphoBorrowFuseEnterData{marketParams, assets}`) and can compute the resulting LTV before
allowing the borrow. I have not written that wrapper — it is a leverage-safety-critical piece that
deserves its own dedicated, audited engineering pass, not a rushed addition to this already-large
package. What I *did* write is a real, achievable **peg-guard pre-hook**
(`LtvPegPreHook.sol`, peg-check portion only — see below), since `isPegHealthy()`/`isFlooredOut()`
need no action-specific calldata and genuinely can be checked pre-execution.

## 7. What compiles now (verified, not claimed)

Against a fresh `IPOR-Labs/ipor-fusion` clone, Foundry 1.7.1, `forge build <file>`:

| File | Result |
|---|---|
| `AguaSupplyFuse.sol` + `AguaBalanceFuse.sol` + `AguaFuseStorageLib.sol` | **Compiles clean** (exit 0) |
| `FXRPPriceFeedEthereum.sol` + `vendor/OracleLibrary.sol` (this package's port) | **Compiles clean** (exit 0), after aligning pragma to the repo's pinned `solc 0.8.30` |

The `vendor/OracleLibrary.sol` gap identified in the earlier round of this work is now closed with
traceable, non-invented code: `TickMath.sol`/`FullMath.sol` copied verbatim from
`ipor-fusion/contracts/fuses/uniswap/ext/` (already used in IPOR's production Uniswap V4/Ramses
fuses), and `getQuoteAtTick` reproduced line-for-line from the real `@uniswap/v3-periphery`
package, just pointed at the 0.8.30-ported files instead of the incompatible 0.7.6 originals.

## 8. CRITICAL: a single `MAX_STALENESS` cannot serve both oracle feeds

Full evidence and remediation in **`GOVERNANCE_PARAMETERS.md`**. Summary:

Measured 17 consecutive Chainlink RLUSD/USD rounds — **every interval is ~86,400 s (24 h)**, min
86,400, max 86,436. Price stayed within ±2.1 bps of $1 throughout, so the feed's 0.3% deviation
trigger never fires; it is a pure 24-hour heartbeat. RedStone XRP/USD, by contrast, was observed
updating **144 s** apart (with a preceding 1,056 s gap) — a minutes-scale cadence.

`FXRPPriceFeedEthereum` applies one immutable `MAX_STALENESS` to both. Traced through the real
code, a value tight enough for XRP makes the peg guard **fail open, silently**:

```
RLUSD stale -> _marketFxrpUsd() returns type(uint256).max
            -> pegDiscountBps() returns 0
            -> isPegHealthy() returns TRUE unconditionally
            -> isFlooredOut() returns FALSE unconditionally
            -> latestRoundData()'s min(xrpMark, market) picks xrpMark, so the NAV writedown never happens
```

At `MAX_STALENESS = 3600`, RLUSD is fresh ~4% of the time — the dual-mark peg protection, which the
spec calls the highest-priority audit item and which marks 100% of collateral, would be **inert
~96% of the time**. A value loose enough for RLUSD (≥86,436 s) instead permits a 24-hour-stale XRP
price on a leveraged position. Both are unsafe; this needs a contract change (split into
`MAX_STALENESS_XRP` / `MAX_STALENESS_RLUSD`), not a better number.

Related: `pegDiscountBps()` returning `0` for "cannot determine" is indistinguishable from
"perfectly healthy", and both consumers treat it as safe. The undeterminable state should fail
**closed**.

## 9. Pool depth measured — supply cap computable, and the v2 estimate was too pessimistic

Ran a QuoterV2 sweep in both directions (read-only, no key). Reproducible via
`script/measure_depth.sh`. Pool holds 966,651 FXRP + 1,961,444 RLUSD (~$2.96M).

| Direction | 1% deviation | 5% deviation |
|---|---|---|
| FXRP→RLUSD (exit/delever) | ~155,000 FXRP | ~807,800 FXRP |
| RLUSD→FXRP (entry) | ~161,000 RLUSD | ~728,800 FXRP-equiv |

Applying the spec §12 formula with the **worse** direction, per the v2 package's own rule:

```
supply_cap = depth_at_5% / (hardMaxLTV × stressMultiple) = 728,800 / (0.40 × 3) = 607,333 FXRP
```

**This contradicts the v2 deployment package**, which estimated *"tens of thousands of FXRP, not
hundreds of thousands"* and declared the spec's illustrative 420,000–830,000 range "void". That
estimate used a constant-product approximation on a **concentrated-liquidity** pool and
under-measured real depth by roughly an order of magnitude. Measured 5% depth is ~$755k, squarely
inside the spec's original $500k–1M illustrative band, and the resulting cap (~607k FXRP) is inside
its original 420k–830k range.

Caveats that must travel with this number: single point-in-time measurement; QuoterV2 simulates
against current state so real execution (MEV, concurrent flow) will be worse; concentrated
liquidity can be withdrawn by its LPs; and 5% slippage is a severe assumption for an emergency
delever. Re-run `measure_depth.sh` immediately before setting the cap on-chain.

## 10. TWAP buffer is the longest-lead blocker, and it is cheap and permissionless

`increaseObservationCardinalityNext` has **no access control** — any funded EOA can call it. It does
not touch vault custody, needs no audit, and no governance vote. At the gas price observed while
writing this (0.07 gwei), growing to cardinality 150 costs **~0.0002 ETH**.

It is nonetheless the item with the longest wall-clock lead, because after the call the ring buffer
must physically fill with observations spanning `TWAP_WINDOW`, and slots are only written when the
pool is traded — on a pool doing ~$84k/24h that is driven by trade arrival, not block production.
Everything downstream (deploying the price feed, calibrating `MAX_DISCOUNT_BPS`, trusting the peg
guard at all) is blocked behind it.

`script/PrepareTwapObservations.s.sol` provides both the transaction and a `check()` view that
reports whether the 900 s TWAP tick has diverged from spot — while they are equal, the buffer has
not filled and the feed must not be deployed.

## 11. LTV enforcement — now written (`contracts/MorphoLtvGuardedFuse.sol`)

Written as a **fuse**, not a pre-hook, for the reason in §6. Instead of simulating the post-action
position, it performs the operation and reads the **real** resulting position back from Morpho,
reverting the transaction if the limit is breached — which removes the replication risk a simulator
would carry. The LTV math mirrors Morpho's own `_isHealthy` exactly, including rounding directions
(borrowed up, collateral value down), so the computed LTV is conservative.

It guards **both** leverage-increasing paths — borrowing *and* collateral withdrawal. Guarding only
the borrow leg would leave collateral withdrawal as an unguarded route to arbitrary LTV. Repay and
`supplyCollateral` are deliberately ungated so an emergency delever can never be blocked, and
collateral withdrawal is deliberately *not* peg-gated for the same reason (its LTV check still
prevents levering up).

Math verified against live mainnet state: 1,000,000 FXRP collateral values at 1,033,509 RLUSD via
Morpho's oracle, and 400,000 RLUSD of debt computes to 3,870 bps — correctly below the 4,000 bps
hard max. Live market params confirmed to match the spec exactly (loanToken RLUSD, collateralToken
FXRP, LLTV `7.7e17` = 77%).

Still unaudited. This contract is the single highest-value audit target in the package.

## 12. Still genuinely blocked

- **Independent security audit** — not done, not attempted here. Now covers the oracle and
  `MorphoLtvGuardedFuse`. (The Agua fuses drop out of scope under a reserve-only Phase 1 — §13.)
- **`MAX_STALENESS` contract change** (§8) — deployment should not proceed on the current
  single-parameter design.
- **TWAP buffer** (§10) — start immediately; longest lead, trivial cost.
- **`MAX_DISCOUNT_BPS`** — uncalibratable until ≥30 days of TWAP history exists.
- **Roles** (§13) — nothing can be configured until OWNER grants ATOMIST and below.
- **Governance decisions**: ownership target, carry-sleeve decision, Morpho-14
  Collateral-vs-Borrow fuse identity confirmation.
- No signer/broadcast capability exists in this environment regardless of the above.

**Removed from this list** (previously listed, since disproven — see §13): WithdrawManager
deployment, the Euler eUSDC-2 fuse instance, and fee-split reconciliation.

## 13. Corrections — three things the documents (and §4 above) got wrong

Verified read-only on 2026-08-09. Each of these removes work that was believed necessary.

**13.1 — The WithdrawManager already exists.** Every document says "NOT DEPLOYED". Reading the
vault's `WITHDRAW_MANAGER` storage slot
(`0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100`) returns
**`0x6d90e8a898280e6a8f0845b80909c5fc2e3d5b03`**, and that contract's `getPlasmaVaultAddress()`
returns the vault — bidirectionally wired. It is a 45-byte EIP-1167 clone, consistent with
`FusionFactoryLogicLib` calling `WithdrawManagerFactory.clone()` during `clone()`.

Current config: `getWithdrawWindow()` = **86400 s** (factory default; spec wants 7 days),
`getWithdrawFee()` = 0, `getRequestFee()` = 0 (both already spec-compliant).

This was worth checking carefully, because `PlasmaVaultLib.updateWithdrawManager` is `internal` and
is called **only** from `PlasmaVault.initialize()` — there is no governance setter. Had the slot
been empty, this shell could never have supported scheduled withdrawals and would have required a
full redeploy. It is set. Remaining work is one call: `updateWithdrawWindow(604800)`.

**13.2 — ERC4626 fuse instances are reusable across vaults.** `Erc4626SupplyFuse.enter/exit` gate on
`PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)` and `Erc4626BalanceFuse`
reads `PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID)` — both resolve against **vault** storage
under delegatecall. The fuse is stateless with respect to *which* ERC4626 vaults are permitted; that
is per-vault configuration. So bzFXRP-ETH can whitelist an already-deployed ERC4626 fuse instance and
grant eUSDC-2 as a substrate in its own storage. No new deployment, no request to IPOR.

**13.3 — Fees are fully reconcilable and the numbers are known.**
`getPerformanceFeeData()` = (`0xC5BdBB34…872F`, 1000), `getManagementFeeData()` =
(`0x7444224f…8e86`, 5). Both are FeeAccount clones whose `FEE_MANAGER()` is
**`0x8a322db71d271bb12132F93F83Bf2a667c64e6B1`**. That FeeManager reports
`getTotalPerformanceFee()` = 1000, `getTotalManagementFee()` = 5, DAO recipient `0xF6a9…5569` —
i.e. IPOR DAO fee package **A (0.05% mgmt / 10% perf)**, with **no curator slice added yet**.

To reach the spec's 50 bps / 15% totals, Bizantine's recipient slice is exactly
**management 45, performance 500**, paid to `0x3D5341AE003BD0cCd05FD38273CC28832205f29E`, via
`updateManagementFee` / `updatePerformanceFee` on that FeeManager.

**13.4 — Control state: only one address can act.** `hasRole` sweep on AccessManager
`0x2BEc…f2E2` across roles 0/1/2/100/200/300/800/1200:

| Account | Roles |
|---|---|
| `0x327d70c3…1474` | **OWNER (1)** |
| Governance Safe `0x3FCA4624…1474` (spec §3) | none |
| Fordefi MPC `0x81Bd7023…Af6e` (spec: ALPHA) | none |
| Hypernative `0x7420fE73…ad1Df` (spec: GUARDIAN) | none |
| IPOR DAO `0xF6a9…5569` | none |

No ATOMIST, FUSE_MANAGER, ALPHA, GUARDIAN, WHITELIST, or PRICE_ORACLE_MIDDLEWARE_MANAGER exists, so
**no configuration call can execute today** except from `0x327d70c3…1474`. Per `Roles.sol` the grant
chain is OWNER → ATOMIST → everything else. Note the on-chain owner is **not** the Governance Safe
the spec names — that discrepancy needs resolving before roles are assigned.

Deposits are currently closed (no WHITELIST_ROLE holder, `totalSupply` 0), which is the correct
safe state.
