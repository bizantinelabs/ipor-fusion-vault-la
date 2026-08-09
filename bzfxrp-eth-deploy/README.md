# bzFXRP-ETH — deployment package

**Status: draft / unaudited. Not deployed. No transaction has been sent.**

`bzFXRP-ETH` is an FXRP-denominated leveraged carry vault (IPOR Fusion PlasmaVault, Ethereum
mainnet) already deployed as an empty shell at `0x8c0127f303d1173229c4bf708b8619909b06a83e`.
This folder captures independent on-chain/repo verification of the deployment spec plus draft
implementations of the pieces that were missing, produced without broadcasting anything and
without inventing any address, ABI, or role id.

## Start here

1. **`FINDINGS.md`** — the verification trail and every correction found.
2. **`GOVERNANCE_PARAMETERS.md`** — a critical oracle defect plus the measured evidence governance
   needs to set the outstanding oracle parameters.

### The two things that should happen first, before anything else

- **Start the TWAP buffer.** `script/PrepareTwapObservations.s.sol`. The pool has
  `observationCardinality = 1`, so any TWAP read today returns spot price with zero manipulation
  resistance — demonstrated by the 900 s TWAP tick coming back bit-for-bit identical to the spot
  tick. The call is **permissionless** (any funded EOA, no vault keys, no governance vote, no audit)
  and cost **~0.0002 ETH** at recently observed gas. But the buffer then has to *fill*, which takes
  wall-clock time on a thinly traded pool — making this the longest-lead blocker in the project.
  Everything downstream is waiting on it.
- **Fix `MAX_STALENESS` before deploying the price feed.** Measured feed cadences differ by ~600x
  (RedStone XRP ~144 s vs Chainlink RLUSD exactly 24 h). One shared staleness parameter cannot serve
  both: set tight, the peg guard silently fails *open* ~96% of the time; set loose, a 24-hour-stale
  XRP price is accepted on a leveraged position. Needs a contract change, not a better number.
  See `GOVERNANCE_PARAMETERS.md` Finding 1.

**`FINDINGS.md` documents:**
- a critical address correction (a shared link resolved to an unrelated, live, funded vault —
  not this one),
- a stale claim in the source spec ("zero fuses") corrected against live chain state,
- a market-ID error in the source spec corrected against `IporFusionMarkets.sol`,
- the Morpho Blue address upgraded from "believed" to independently confirmed on-chain,
- real fuse addresses discovered by reading `getFuses()` on comparable live vaults instead of
  guessing,
- what could and couldn't be corroborated about the external `Agua` vault's interface,
- an architectural finding that the spec's "LTV pre-hook" cannot be implemented as a generic
  `IPreHook` given the real `PreHooksHandler` code, and what the correct fix looks like instead.

## Contents

- `contracts/FXRPPriceFeedEthereum.sol` — the supplied dual-mark oracle, with its missing
  `vendor/OracleLibrary.sol` dependency reconstructed from IPOR's own already-ported
  `TickMath.sol`/`FullMath.sol` (verbatim copies in `contracts/vendor/`), not invented math.
  **Compiles clean** against a fresh `IPOR-Labs/ipor-fusion` clone (Foundry 1.7.1).
- `contracts/AguaSupplyFuse.sol`, `AguaBalanceFuse.sol`, `AguaFuseStorageLib.sol` — draft custom
  fuses for the non-4626-compliant `Agua` external vault. View-function behavior was cross-checked
  live on mainnet; state-changing function signatures are taken from the deployment package's
  prose and are explicitly flagged `UNVERIFIED SIGNATURE` at every call site. **Compiles clean.**
- `contracts/PegGuardPreHook.sol` — the achievable half of the spec's pre-hook design (peg check
  only; needs no action-specific calldata). **Compiles clean.**
- `contracts/MorphoLtvGuardedFuse.sol` — **the leverage limit enforcement.** Written as a fuse
  rather than a pre-hook (see `FINDINGS.md` §6). Performs the operation then checks the *real*
  resulting Morpho position and reverts on breach, instead of simulating — which removes any risk
  of drifting out of sync with Morpho's arithmetic. Guards **both** LTV-increasing paths (borrow
  *and* collateral withdrawal); leaves repay/supply ungated so an emergency delever can never be
  blocked. Math mirrors Morpho's own `_isHealthy` including rounding directions, and was verified
  against live mainnet state. **Compiles clean.** Highest-value audit target here.
- `script/PrepareTwapObservations.s.sol` — starts the TWAP observation buffer, plus a `check()`
  view that tells you whether it has actually filled yet. **Compiles clean.**
- `script/measure_depth.sh` — reproducible QuoterV2 depth sweep (read-only, no key) feeding the
  supply-cap formula. Verified working; results in `FINDINGS.md` §9.
- `script/ConfigureBzFxrpEth.s.sol` — config-only draft script (roles, RLUSD/USDC price
  registration, Morpho + swapper fuse whitelist, substrates, placeholder market limits) against
  the existing shell. Deliberately excludes FXRP price registration, the eUSDC-2 reserve leg
  (no fuse instance exists yet), Agua, and LTV enforcement — none of those exist yet. **Compiles
  clean** but is explicitly marked DO NOT BROADCAST in its header.

## What remains blocked regardless of anything in this folder

Independent security audit (now covering the oracle, the Agua fuses, and `MorphoLtvGuardedFuse`);
the `MAX_STALENESS` contract change; the TWAP buffer fill; `MAX_DISCOUNT_BPS` calibration (needs
≥30 days of TWAP history); WithdrawManager deployment; a real ERC4626 fuse instance for Euler
eUSDC-2; and governance sign-off on fee split / DAO package / role assignments.

Pool depth is no longer a blocker — it is measured (`FINDINGS.md` §9), yielding a computed cap of
~607,000 FXRP, which notably **corrects** the earlier v2 package's "tens of thousands" estimate.

No signer or broadcast capability was used or is available in the environment that produced this
package, and no private key should ever be pasted into a chat transcript to change that.
