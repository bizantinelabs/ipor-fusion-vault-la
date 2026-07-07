# On-chain verification record — cbBase USDC CORE

**Date:** 2026-07-07  **Chain:** Base (8453)  **Method:** `eth_call` (browser UA) via `base.drpc.org`
(rotating fallbacks). Addresses sourced from IPOR `ipor-abi` registry
`mainnet/mainnet-base-fusion/addresses.json`, then each verified by reading its immutable getters.

Selectors = `keccak256(sig)[:4]`.

| contract | address | call | result | expected | ✓ |
|---|---|---|---|---|---|
| SupplyFuseMorpho | 0xae93EF3cf337b9599F0dfC12520c3C281637410F | `MARKET_ID()` | 14 | 14 | ✓ |
| SupplyFuseMorpho | " | `MORPHO()` | 0xbbbb…ffcb | 0xBBBB…FFCb (Morpho Blue Base) | ✓ |
| BalanceFuseMorpho | 0x7916856E11E0CA021967D0D4daC49D737b7d73d5 | `MARKET_ID()` | 14 | 14 | ✓ |
| SupplyFuseAaveV3 | 0x26fD6EF391E98C78CfCA27e00c3d15be4D941625 | `MARKET_ID()` | 1 | 1 | ✓ |
| SupplyFuseAaveV3 | " | `AAVE_V3_POOL_ADDRESSES_PROVIDER()` | 0xe20f…d64d | 0xe20f…d64D | ✓ |
| BalanceFuseAaveV3 | 0xf53f3EaFfDf67539256365cA7299540A98b60BA9 | `MARKET_ID()` | 1 | 1 | ✓ |
| AaveV3PoolAddressesProvider | 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D | `getPool()` | 0xa238…d1c5 | Aave V3 Base Pool | ✓ |
| FusionFactory | 0x1455717668fA96534f675856347A973fA907e922 | `getDaoFeePackagesLength()` | 3 | ≥1 | ✓ |
| FusionFactory | " | `getWithdrawWindowInSeconds()` | 86400 | >0 | ✓ |
| FusionFactory | " | `getDaoFeePackage(0)` | mgmt 5 / perf 1000 bps | — | (0.05%/10%) |
| FusionFactory | " | `getDaoFeePackage(1)` | mgmt 30 / perf 200 bps | 0.3%/2% | ✓ SELECTED |
| FusionFactory | " | `getDaoFeePackage(2)` | mgmt 50 / perf 0 bps | — | (0.5%/0%) |
| SupplyFuseCompoundV3WEth | 0xD72Dd19C04362488a4143F43e407ec87A849b72b | `MARKET_ID()` | 26 | (proves NOT USDC=2) | ✓ |
| SupplyFuseCompoundV3WEth | " | `COMPOUND_BASE_TOKEN()` | 0x4200…0006 (WETH) | (proves WETH comet) | ✓ |

**Fee package scale:** FeeManager uses percentage with 2 decimals (10000 = 100%). Raw pkg values are
basis points: 30 = 0.30%, 200 = 2.00%.

**Re-verify before broadcast** (belt-and-suspenders): re-run these reads at deploy time (addresses are
immutable but confirm no registry change), and confirm the price feeds needed by the Aave/Morpho
balance fuses resolve in the vault's `priceManager`.

---

## Build & fork-sim actually executed (Foundry 1.7.1, 2026-07-07)

Ran against a fresh clone of `IPOR-Labs/ipor-fusion` (submodules + `npm install`), script pragma
aligned to the repo's pinned `solc 0.8.30` (exact `0.8.26` fails inside the repo — the only change
made to the script; no constants/addresses touched). No broadcast; no key used.

- `forge build script/DeployCbBaseUsdcCore.s.sol` → **compiles clean** (warnings only).
- `forge script …:DeployCbBaseUsdcCore --rpc-url <base>` (NO `--broadcast`):
  - **`FusionFactory.clone(...)` SUCCEEDS on the Base fork** against the real factory
    `0x1455717668fA96534f675856347A973fA907e922`. Emits `FusionInstanceCreated(index 193, version 8)`
    with the correct identity — `name "Bizantine cbBase USDC CORE"`, `symbol "bizcbBaseUSDC"`,
    `underlyingToken USDC`, `underlyingTokenDecimals 6`, `initialOwner 0x327d70c3…1474` (Fordefi owner),
    `daoFeePackageIndex 1` accepted. This validates the factory address, `clone` signature, identity,
    and DAO fee package end-to-end on live state.
  - `assetDecimals` on the share token is **8** (= underlying 6 + IPOR's standard ERC-4626 decimals
    offset of 2, for inflation-attack protection). Expected, not a misconfiguration.
  - `run()` then **reverts at `addFuses(...)` with `AccessManagedUnauthorized(<default sender>)`**.
    Expected: config calls (steps 2–9) are role-restricted and the vault (owner = Fordefi Safe) grants
    no `FUSE_MANAGER_ROLE` to the broadcasting EOA. Per the wizard model (RESOLUTIONS §8.3), those
    steps must be run from the account the IPOR wizard grants `FUSE_MANAGER`/`ATOMIST` to — or in the
    wizard UI. A script-only fork-sim cannot proceed past this without pranking as a role holder,
    which was deliberately not done (no script logic changes).

**Net:** the deployable prefix (clone + identity + fees package) is verified live; the config tail is
gated on the wizard granting roles to the deployer/role-holder, which is an operator step, not a code
fix. Simulation-only vault address this run was `0x060f0177…865D9` (fork-dependent on the factory's
clone index; the real address at broadcast will differ).
