# Bizantine IPOR Fusion Alpha Automation

This repository contains a conservative operator-bot scaffold for an existing USDC IPOR Fusion Plasma Vault. It uses the official `ipor-fusion` Python SDK and does **not** build a custom vault contract.

## What it does

1. Reads vault, fuse, market, and allocation-policy config.
2. Creates an SDK `Web3Context` from an RPC URL.
3. Loads a `PlasmaVault` wrapper.
4. Fetches basic vault info.
5. Reads the USDC allocation policy.
6. Produces a rebalance recommendation.
7. Refuses live execution by default.
8. Requires `--execute` plus `OPERATOR_PRIVATE_KEY` for live transactions.
9. Scaffolds Morpho `MorphoSupplyFuse` action creation.
10. Leaves Euler and Superform/USDT0 action creation as explicit TODO placeholders.

## Repository layout

```text
config/
  vaults.json
  fuses.json
  allocation_policy.json
  approved_markets.json
bot/
  context.py
  vault_state.py
  risk.py
  yields.py
  rebalance.py
  execute.py
  report.py
scripts/
  vault_info.py
  propose_rebalance.py
  execute_rebalance.py
  report_allocations.py
docs/
  strategy.md
  operations.md
  risk-framework.md
.env.example
requirements.txt
```

## Install

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Populate RPC URLs in `.env`. Do not put private keys in repository files.

## Configure

- Set the real vault address in `config/vaults.json`.
- Set approved fuse addresses in `config/fuses.json`.
- Add approved opportunities in `config/approved_markets.json` and set `enabled: true` only after manual approval.
- Keep `config/allocation_policy.json` aligned with the risk framework.

## Run

Offline recommendation using configured allocations only:

```bash
python scripts/propose_rebalance.py --offline
```

Read vault state and produce a recommendation:

```bash
python scripts/propose_rebalance.py
```

Dry-run execution path:

```bash
python scripts/execute_rebalance.py
```

Live execution after manual approval:

```bash
export OPERATOR_PRIVATE_KEY=0x...
python scripts/execute_rebalance.py --execute
```

## Safety rules

- USDC accounting/deposit asset only.
- Ethereum, Base, and Flare where supported.
- Morpho, Euler, and Superform/USDT0 only.
- Manual approval first.
- No leverage.
- No recursive loops.
- No unapproved routes.
- No private keys in repo.

## Live data via MCP

This repo registers the official IPOR Fusion MCP server (`https://mcp.ipor.io/`)
in [`.mcp.json`](.mcp.json), giving Claude Code and other MCP clients
read-only access to live vault, deployment, and Morpho market data. See
[`docs/mcp.md`](docs/mcp.md) for the available tools and how to enable it.
