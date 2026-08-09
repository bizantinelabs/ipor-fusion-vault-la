# bzFXRP-ETH — deployment package

**Status: draft / unaudited. Not deployed. No transaction has been sent.**

`bzFXRP-ETH` is an FXRP-denominated leveraged carry vault (IPOR Fusion PlasmaVault, Ethereum
mainnet) already deployed as an empty shell at `0x8c0127f303d1173229c4bf708b8619909b06a83e`.
This folder captures independent on-chain/repo verification of the deployment spec plus draft
implementations of the pieces that were missing, produced without broadcasting anything and
without inventing any address, ABI, or role id.

**Read `FINDINGS.md` first.** It documents:
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
  only; needs no action-specific calldata). Does **not** implement the LTV guard — see
  `FINDINGS.md` §6 for why that must live in a custom Morpho borrow-fuse wrapper instead, which is
  not written here. **Compiles clean.**
- `script/ConfigureBzFxrpEth.s.sol` — config-only draft script (roles, RLUSD/USDC price
  registration, Morpho + swapper fuse whitelist, substrates, placeholder market limits) against
  the existing shell. Deliberately excludes FXRP price registration, the eUSDC-2 reserve leg
  (no fuse instance exists yet), Agua, and LTV enforcement — none of those exist yet. **Compiles
  clean** but is explicitly marked DO NOT BROADCAST in its header.

## What remains blocked regardless of anything in this folder

Independent security audit, Uniswap V3 pool depth measurement → supply cap, WithdrawManager
deployment, a real ERC4626 fuse instance for Euler eUSDC-2, the LTV-enforcing Morpho fuse wrapper,
and governance sign-off on fee split / DAO package / role assignments. No signer or broadcast
capability was used or is available in the environment that produced this package.
