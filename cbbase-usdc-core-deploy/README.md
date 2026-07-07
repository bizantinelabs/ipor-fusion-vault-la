# Bizantine cbBase USDC CORE — deployment package

Hand `DEPLOY_PROMPT.md` to Claude Code as the task brief. It deploys an IPOR Fusion Plasma Vault on Base.

Files:
- `DEPLOY_PROMPT.md` — the Claude Code brief (start here). Pre-flight gate, real ipor-fusion API, build/verify flow, guardrails.
- `config/cbbase_usdc_core.json` — every locked parameter + the address slots to fill from Pavel.
- `script/DeployCbBaseUsdcCore.s.sol` — Foundry scaffold grounded in real ipor-fusion interfaces (FusionFactory.clone → governance config → roles → fees).
- `VERIFY.md` — post-deploy checklist incl. negative tests + guardian dry-run.
- `.env.example` — RPC / keys for sim + verify.

Prereqs: clone IPOR-Labs/ipor-fusion, solc 0.8.26, Foundry. The scaffold will NOT compile/run until
the `address(0)` / `CONFIRM_WITH_PAVEL` slots are filled — that's intentional (see pre-flight gate).

Status: 6 Morpho market ids + caps + roles + fees + name/symbol are LOCKED. Pending from Pavel:
FusionFactory address, per-marketId fuse instances, RewardsClaimManager+swap fuse, PriceOracleMiddleware+feed,
Aave PoolAddressesProvider, daoFeePackageIndex, IPOR Alpha account, Hypernative guardian.
