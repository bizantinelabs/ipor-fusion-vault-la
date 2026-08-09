# Bizantine cbBase USDC CORE — deployment package

Hand `DEPLOY_PROMPT.md` to Claude Code as the task brief. It deploys an IPOR Fusion Plasma Vault on Base.

Files:
- `DEPLOY_PROMPT.md` — the Claude Code brief (start here). Pre-flight gate, real ipor-fusion API, build/verify flow, guardrails.
- `config/cbbase_usdc_core.json` — every locked parameter + the address slots to fill from Pavel.
- `script/DeployCbBaseUsdcCore.s.sol` — Foundry scaffold grounded in real ipor-fusion interfaces (FusionFactory.clone → governance config → roles → fees).
- `ONCHAIN_VERIFICATION.md` — raw on-chain reads confirming every factory/fuse/provider address (2026-07-07).
- `RESOLUTIONS.md` — worked answers to the open items + the canonical marketId model (read first).
- `VERIFY.md` — post-deploy checklist incl. negative tests + guardian dry-run.
- `.env.example` — RPC / keys for sim + verify.

Prereqs: clone IPOR-Labs/ipor-fusion, solc 0.8.26, Foundry. The scaffold will NOT compile/run until
the `address(0)` / `CONFIRM_WITH_PAVEL` slots are filled — that's intentional (see pre-flight gate).

See **RESOLUTIONS.md** for the worked answers to the open items (canonical marketId model, DAO fee split,
withdraw window, Safe/Base check). Still needed before broadcast: 7 canonical Base fuse addresses,
FusionFactory Base address, IPOR Alpha address, Hypernative guardian, Aave PoolAddressesProvider,
Fordefi Base enablement, and the Option A/B per-cb-caps decision.
