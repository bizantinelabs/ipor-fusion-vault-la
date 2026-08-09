# bzFXRP-ETH — oracle parameter memo for governance

**Purpose:** `FXRPPriceFeedEthereum`'s constructor takes `MAX_STALENESS`, `TWAP_WINDOW`, and
`MAX_DISCOUNT_BPS`. All three are listed in the spec as requiring explicit governance approval and
all three are currently blank. This memo supplies measured evidence so those values can be decided
rather than guessed.

**Measurement date:** 2026-08-09, Ethereum mainnet, via `cast` against a public RPC.

---

## FINDING 1 — CRITICAL: a single `MAX_STALENESS` cannot serve both feeds

This is a design defect in the supplied contract, not a parameter-tuning question. It should block
deployment until resolved, and it belongs at the top of the audit scope.

### The measurement

**Chainlink RLUSD/USD (`0x26C46B7a…7f2A`)** — walked 17 consecutive historical rounds
(aggregator rounds 806–822, phase 1) and computed the interval between every `updatedAt`:

| Interval | Seconds |
|---|---|
| 822←821 | 86,412 |
| 821←820 | 86,412 |
| 820←819 | 86,412 |
| 819←818 | 86,424 |
| 818←817 | 86,436 |
| 817←816 | 86,436 |
| 816←815 | 86,412 |
| 815←814 | 86,424 |
| 814←813 | 86,424 |
| 813←812 | 86,424 |
| 812←811 | 86,400 |
| 811←810 | 86,436 |
| 810←809 | 86,424 |
| 809←808 | 86,424 |
| 808←807 | 86,424 |
| 807←806 | 86,436 |

**Every single interval is ~86,400s (24h). Min 86,400, max 86,436.** Across those 16 intervals the
price stayed within `0.99987–1.00021` — i.e. ±2.1 bps of $1. The feed's 0.3% deviation trigger
therefore **never fires**; RLUSD/USD is, in practice, a pure 24-hour heartbeat feed.

**RedStone XRP/USD (`0x64775db2…b22d`)** — this feed returns `roundId = 1` permanently (a
non-incrementing push feed), so history cannot be walked by round. Instead I sampled
`latestRoundData()` at historical blocks. Public RPC archive depth is limited to ~128 blocks, but
within that window two distinct updates were captured:

| Block | `updatedAt` | Price (8dp) | Gap |
|---|---|---|---|
| 25,716,288 | 1,786,264,799 | 103,310,318 | — |
| 25,716,300 | 1,786,264,943 | 103,147,746 | **144 s** |

with a preceding gap of 1,056 s. The price moved −0.157% across the 144-second update, consistent
with deviation-triggered pushing. **RedStone XRP operates on a minutes-scale cadence.**

Its heartbeat *ceiling* could not be established from the available archive depth — that should be
confirmed with RedStone directly or via an archive node before finalizing values.

### Why this breaks the contract

`MAX_STALENESS` is a single immutable applied to **both** feeds:

```solidity
// XRP path — reverts NAV pricing when stale
if (block.timestamp - updated > MAX_STALENESS) revert StalePrice(updated, MAX_STALENESS);

// RLUSD path — silently degrades when stale
if (rlusdUsd <= 0 || block.timestamp - updated > MAX_STALENESS) return type(uint256).max;
```

The two feeds' cadences differ by roughly **two to three orders of magnitude** (144 s vs 86,400 s).
No single value can be correct for both:

**If tuned for XRP (tight, e.g. 3,600 s): the peg guard silently fails open.**
Trace it through the real code:

1. RLUSD is older than `MAX_STALENESS` → `_marketFxrpUsd()` returns `type(uint256).max`
2. → `pegDiscountBps()` hits `if (market == type(uint256).max …) return 0`
3. → `isPegHealthy()` returns `0 <= PEG_TOLERANCE_BPS` = **`true`, unconditionally**
4. → `isFlooredOut()` returns `0 > MAX_DISCOUNT_BPS` = **`false`, unconditionally**
5. → in `latestRoundData()`, `min(xrpMark, market)` selects `xrpMark`, so **the NAV writedown
   never happens** and the vault marks bridged FXRP at native XRP price

With `MAX_STALENESS = 3,600`, RLUSD is fresh for 3,600 of every ~86,400 seconds — so the entire
dual-mark peg protection is **inert roughly 96% of the time**, and it fails *open* (permissive),
not closed. The spec's own §5.2 anticipates this degradation as an exceptional condition requiring
an alert; the measurements show it would be the **normal steady state**.

| `MAX_STALENESS` | Fraction of time RLUSD is fresh → peg guard actually functional |
|---|---|
| 3,600 s (1 h) | ~4% |
| 7,200 s (2 h) | ~8% |
| 21,600 s (6 h) | ~25% |
| 43,200 s (12 h) | ~50% |
| ≥86,436 s (24 h) | ~100% |

**If tuned for RLUSD (loose, ≥86,436 s): stale-XRP protection is destroyed.**
A 24-hour-old XRP price would pass the freshness check and be accepted as the NAV mark for a
*leveraged* position on a volatile asset. RedStone is already flagged in the spec as the single
point of failure in the entire price stack; a 24h staleness tolerance on it is not acceptable.

Both settings are unsafe. The parameter cannot be fixed by choosing a better number.

### Recommended remediation

Split the parameter in the contract before deployment:

```solidity
uint256 public immutable MAX_STALENESS_XRP;    // governs the XRP/USD revert path
uint256 public immutable MAX_STALENESS_RLUSD;  // governs the RLUSD degradation path
```

Suggested starting values, pending confirmation of RedStone's heartbeat ceiling:

| Parameter | Suggested | Rationale |
|---|---|---|
| `MAX_STALENESS_XRP` | RedStone's stated heartbeat + ~20% margin | Must revert NAV on genuinely stale XRP. Do **not** set from observed 144 s cadence — that is the deviation-driven interval, not the heartbeat ceiling. Confirm the ceiling first. |
| `MAX_STALENESS_RLUSD` | **90,000 s** | Max observed interval 86,436 s + ~4% margin. Anything below ~86,500 s makes the peg guard mostly inert. |

Additionally, and independent of the split: **`pegDiscountBps()` returning `0` to mean "cannot
determine" is unsafe**, because `0` is indistinguishable from "perfectly healthy peg" and both
`isPegHealthy()` and `isFlooredOut()` treat it as the safe case. The unknown state should be
surfaced explicitly (e.g. a separate `isPegDeterminable()` view, or reverting) so that monitoring
and any consuming hook can fail **closed** rather than open.

---

## FINDING 2 — `TWAP_WINDOW` cannot be honored by the pool today

`slot0()` on the FXRP/RLUSD pool (`0x42271FcA…1782`) returns:

```
observationCardinality     = 1
observationCardinalityNext = 1
```

Nobody has called `increaseObservationCardinalityNext`. With cardinality 1 the pool stores a single
observation, so `observe([900, 0])` does **not** revert — it silently returns a value derived from
the only datapoint available. Demonstrated directly: the tick computed from a nominal 900-second
TWAP was **bit-for-bit identical** to the current spot tick from `slot0()` (−276,722 in both cases).

**Any `TWAP_WINDOW` configured today yields spot price with zero manipulation resistance.**

`TWAP_WINDOW ≥ 900 s` per the spec is fine as a *value*, but it is not meaningful until:
1. someone calls `increaseObservationCardinalityNext(N)` on the pool, **and**
2. enough wall-clock time passes for the ring buffer to actually fill past the window.

See `script/PrepareTwapAndDepth.s.sol` in this folder for the exact call. This is the longest-lead
blocker in the whole project and it needs no audit, no governance decision, and no custom code —
only a funded EOA and elapsed time. **It should be started immediately, ahead of everything else.**

---

## FINDING 3 — `MAX_DISCOUNT_BPS` cannot be calibrated from current data

`MAX_DISCOUNT_BPS` is the loss-recognition floor: how far below the XRP mark the NAV mark is
permitted to track before it pins and `isFlooredOut()` trips. Setting it requires the observed
distribution of the FXRP/XRP spread, which requires TWAP history that does not exist yet
(Finding 2).

One correction to an earlier working assumption: a draft in the deployment package flagged a
persistent "~4% FXRP/RLUSD spread" needing explanation. Measured live, that spread is **not**
present today — the Morpho oracle's implied FXRP/RLUSD rate is consistent with RedStone XRP/USD to
within a few bps, i.e. FXRP is trading at approximately parity with XRP. The ~4% figure appears to
have come from a stale snapshot. `MAX_DISCOUNT_BPS` should therefore **not** be sized to
accommodate a 4% standing discount.

`PEG_TOLERANCE_BPS = 200` is specified and needs no new measurement, but note it is only meaningful
once Findings 1 and 2 are resolved — until then `isPegHealthy()` is either inert (Finding 1) or
reading spot (Finding 2).

**Recommendation:** do not set `MAX_DISCOUNT_BPS` now. Fix cardinality, accumulate ≥30 days of TWAP
history per the spec's own extended proving period, then calibrate against the real observed
distribution and bring a specific number to governance with the data attached.

---

## Summary for the governance vote

| Parameter | Status | Blocking on |
|---|---|---|
| `MAX_STALENESS` | **Do not set — contract change required first** | Splitting into XRP/RLUSD variants (Finding 1) |
| `MAX_STALENESS_XRP` | Proposed: RedStone heartbeat + 20% | Confirming RedStone's heartbeat ceiling |
| `MAX_STALENESS_RLUSD` | Proposed: **90,000 s** | Ready to approve — evidence above |
| `TWAP_WINDOW` | ≥900 s acceptable as a value | Pool cardinality + fill time (Finding 2) |
| `MAX_DISCOUNT_BPS` | **Do not set yet** | ≥30 days TWAP history (Findings 2, 3) |
| `PEG_TOLERANCE_BPS` | 200 per spec | No new measurement needed |

Nothing in this memo was assumed from documentation. Every number above was read from mainnet on
2026-08-09 and the exact commands are reproducible from `script/PrepareTwapAndDepth.s.sol` and the
`cast` invocations recorded in `FINDINGS.md`.
