# Finalizing bzFXRP-ETH (`0x8c0127f3…b06a83e`)

## Context

The vault is a deployed but unconfigured IPOR Fusion shell on Ethereum mainnet: correct identity
(name/symbol/FXRP/8dp), `totalAssets = 0`, no strategy fuses, no substrates, limits inactive,
uncapped supply, and FXRP itself unpriced. It cannot value its own underlying asset, so it cannot
accept a deposit. This plan takes it from that state to a configured, deposit-ready vault.

Three findings from this session materially change the shape of the work versus what the existing
documents assume — two of them remove blockers, one adds a hard one.

## What is actually true right now (verified read-only, 2026-08-09)

| Item | Document says | Actually |
|---|---|---|
| WithdrawManager | "NOT DEPLOYED" — a launch blocker | **Exists** at `0x6d90e8a8…5b03`, bidirectionally wired, window 86400 s |
| eUSDC-2 ERC4626 fuse | "does not exist, must be deployed" | **Reusable** — existing instances work; substrates are per-vault |
| Fee split | "unverified, unknown recipients" | DAO package A applied; FeeManager `0x8a322db7…e6B1`; curator slice = **mgmt 45 / perf 500** |
| Roles | Safe/Fordefi/Hypernative assigned | **Only `0x327d70c3…1474` holds OWNER.** Everything else unassigned |
| Supply cap | "tens of thousands of FXRP" (v2) | **~607,000 FXRP** from measured depth |
| Market 19 | "idle/ERC-20" | `MORPHO_FLASH_LOAN`; idle is market **7** |

The WithdrawManager finding is the most consequential: `updateWithdrawManager` is `internal` and
runs **only** inside `PlasmaVault.initialize()`. Had the slot been empty, this shell could never
support scheduled withdrawals and would have needed a full redeploy. It is set — so finalization
is a configuration exercise, not a redeployment.

## Two things gate everything else

**1. Start the TWAP buffer today.** The pool has `observationCardinality = 1`, so every TWAP read
returns spot price — demonstrated by the 900 s TWAP tick coming back bit-for-bit equal to spot.
The call is permissionless (any funded EOA, no vault keys, no audit, no vote) and costs ~0.0002 ETH,
but the buffer then fills only as trades arrive on a thin pool. Nothing involving the oracle, the
peg guard, or `MAX_DISCOUNT_BPS` is trustworthy until it fills. Longest lead item, cheapest action.
Use `script/PrepareTwapObservations.s.sol`; poll its `check()` until the TWAP tick diverges from spot.

**2. Fix `MAX_STALENESS` before the price feed ships.** One immutable governs two feeds whose
cadences differ ~600x (RedStone XRP ~144 s; Chainlink RLUSD exactly 24 h, measured across 17
consecutive rounds). Tight → stale RLUSD makes `pegDiscountBps()` return 0, so `isPegHealthy()` is
unconditionally true and the NAV writedown never fires: the peg guard **fails open, silently, ~96%
of the time**. Loose → a 24-hour-stale XRP price is accepted on a levered position. Split into
`MAX_STALENESS_XRP` / `MAX_STALENESS_RLUSD` and make the undeterminable peg state fail **closed**.
Detail in `bzfxrp-eth-deploy/GOVERNANCE_PARAMETERS.md`.

## Recommended scope: Phase 1 launches reserve-only

`bizFXRP-ETH_FULL_SPEC.md` v1.1 (the controlling baseline) §8/§21 removes Agua from the strategy and
puts the Symbiotic replacement at a **zero market limit** until a full evidence package clears. §10
says the carry allocation stays in approved liquid reserve venues until then. So Phase 1 needs **no
carry sleeve at all** — the 45/55 split runs entirely through Euler eUSDC-2 + Aave V3.

This removes the Agua/Symbiotic fuses, their epoch/redemption state machines, and their audits from
the critical path. It is the single largest scope reduction available, and it is what the spec
already asks for. The drafted `AguaSupplyFuse`/`AguaBalanceFuse` stay in the repo, unused and
unaudited, until a sleeve decision is actually made.

Economics still clear the §15 gate without the sleeve and with Merkl set to zero (the campaign
expires 2026-09-03 and will be gone before launch): reserve yield alone against a ~3.59%
unsubsidised borrow cost leaves headroom above the 150 bps hurdle. **Recompute at intended size
immediately before launch** — Euler's quoted rate collapses as you size into it.

## Workstreams

These run in parallel; only Track A has a wall-clock floor.

**A. TWAP + oracle (longest lead)**
- Call `increaseObservationCardinalityNext(150)`; poll `check()` until filled.
- Split `MAX_STALENESS`; add a determinable-peg signal that fails closed. `FXRPPriceFeedEthereum.sol`.
- Once filled: measure the FXRP/XRP spread distribution, then set `MAX_DISCOUNT_BPS` with evidence.
- Deploy the feed, cross-check `ltvBps()` and the NAV mark against independent calculation.

**B. Roles** — `0x327d70c3…1474` is the only actor able to move. Chain is OWNER → ATOMIST → the rest.
Resolve the discrepancy that the on-chain owner is *not* the Governance Safe named in §3, then grant:
ATOMIST (timelocked ≥24 h) → Governance Safe; ALPHA (0 delay) → Fordefi MPC; GUARDIAN (0 delay) →
Hypernative; plus FUSE_MANAGER / CONFIG_INSTANT_WITHDRAWAL / WHITELIST / PRICE_ORACLE_MW_MANAGER.
Confirm no zero-delay path can expand the strategy surface, and confirm ADMIN(0) is unheld.

**C. Fees** — on FeeManager `0x8a322db7…e6B1`: `updateManagementFee([(0x3D5341AE…, 45)])` and
`updatePerformanceFee([(0x3D5341AE…, 500)])`, giving spec totals of 50 bps / 15%. Verify totals read
back as 50 / 1500.

**D. Fuses, substrates, limits** — whitelist Morpho collateral/borrow/flash-loan + balance, Universal
Swapper, ERC4626 supply + balance, Aave V3 supply + balance. Resolve each address from IPOR's registry
and **verify `MARKET_ID()` on-chain before use** (two market-14 instances remain unidentified as
collateral-vs-borrow). Substrates: Morpho → FXRP/RLUSD id only; ERC4626 → eUSDC-2 only; swapper →
named Curve pool + tokens only; idle → market **7**. Then set every limit explicitly and call
`activateMarketsLimits()`.

**E. Leverage enforcement** — deploy `MorphoLtvGuardedFuse` (33% target / 40% hard max, peg-gated on
increase, guarding both borrow *and* collateral withdrawal) and route the Alpha through it. Do **not**
whitelist a raw `MorphoBorrowFuse` alongside it — that would bypass the guard entirely.

**F. Withdrawals** — `WithdrawManager.updateWithdrawWindow(604800)` (24 h → 7 days). Instant-withdrawal
list stays empty. Fees already 0.

**G. Cap** — re-run `script/measure_depth.sh` same-day, then `setTotalSupplyCap` to the freshly computed
figure (~607,000 FXRP at last measurement). Never carry a stale number.

**H. Audit** — scope: `FXRPPriceFeedEthereum` (marks 100% of collateral), `MorphoLtvGuardedFuse` (sole
leverage enforcement), and the full configuration. Agua fuses out of scope under reserve-only.

## Execution order

1. Track A cardinality call **now** (unblocks nothing else, blocks everything later).
2. B (roles) — required before any other config call can execute.
3. C, D, F in one batch once ATOMIST/FUSE_MANAGER exist.
4. A oracle contract fix + feed deploy, once the buffer has filled and parameters are approved.
5. E (LTV fuse) — after the feed exists, since the guard depends on `isPegHealthy()`.
6. G (cap) immediately before opening.
7. Dead deposit to block first-depositor inflation; confirm no residual privileged EOA.
8. ≥14-day proving period with governance capital only — two real-size atomic delevers, pause/depeg/
   stale-oracle drills, Hypernative alert verification.
9. Public open (`convertToPublicVault` / whitelist removal) as a separate, explicit, irreversible
   governance action referencing a signed-off audit. **Not** covered by this plan.

## Files

- `bzfxrp-eth-deploy/script/PrepareTwapObservations.s.sol` — step 1, plus `check()`
- `bzfxrp-eth-deploy/contracts/FXRPPriceFeedEthereum.sol` — the `MAX_STALENESS` split
- `bzfxrp-eth-deploy/contracts/MorphoLtvGuardedFuse.sol` — leverage enforcement
- `bzfxrp-eth-deploy/script/ConfigureBzFxrpEth.s.sol` — extend for tracks C/D/F; correct its
  placeholder market limits and its idle market id
- `bzfxrp-eth-deploy/script/measure_depth.sh` — step G
- `bzfxrp-eth-deploy/GOVERNANCE_PARAMETERS.md` — parameter evidence

## Verification

- Fork-rehearse the whole sequence on an anvil mainnet fork with a locally generated throwaway key
  before any mainnet broadcast. This is the highest-value validation available and costs nothing.
- Post-config asserts: `getTotalSupplyCap()` finite; `isMarketsLimitsActivated()` true and every
  `getMarketLimit` non-default; `getInstantWithdrawalFuses()` empty; window 604800; FeeManager totals
  50 / 1500 to `0x3D5341AE…`; `getAssetPrice(FXRP)` and `(RLUSD)` both return sane values.
- Negative tests: Alpha cannot add fuses/substrates/limits/fees/roles; Alpha cannot move assets
  externally; a borrow that would breach 40% LTV reverts; Guardian pause works independently of Alpha.

## Assumptions needing confirmation

1. **Reserve-only Phase 1** (no Agua, no Symbiotic) — follows spec v1.1 but contradicts the older PDF.
2. **Ownership target** — on-chain OWNER `0x327d70c3…1474` differs from the Safe named in §3; plan
   assumes it moves to the Safe with Fordefi as ALPHA.
3. **End state is whitelisted, governance-capital-only** — public launch deliberately excluded.
4. I have no signer here; every step above is executed by whoever holds the keys, and no private key
   should be shared into a chat transcript to change that.
