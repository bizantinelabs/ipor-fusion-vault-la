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

**Confirmed gap:** neither existing ERC4626 market instance on `bdUSD` (100001 → substrate
`0x3bc80141...`, 100002 → substrate `0xa3931d71...`) targets Euler eUSDC-2
(`0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9`). **No shared ERC4626 fuse instance for eUSDC-2
exists yet** — this must be requested from IPOR or freshly deployed, same "per-instance" pattern
found during the earlier cbBase-USDC-CORE work on Base.

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

## 8. Still genuinely blocked (unchanged by anything above)

- Independent security audit — not done, not attempted here.
- Uniswap V3 FXRP/RLUSD pool depth measurement (1%/5% slippage) → supply cap.
- WithdrawManager — not deployed.
- Euler eUSDC-2 ERC4626 fuse instance — does not exist yet (§4).
- LTV enforcement — needs the custom Morpho fuse wrapper described in §6, not yet written.
- Governance decisions: fee-split reconciliation, DAO package confirmation, Morpho-14
  Collateral-vs-Borrow fuse identity confirmation, Origin/Symbiotic-style sleeve evidence review.
- No signer/broadcast capability exists in this environment regardless of the above.
