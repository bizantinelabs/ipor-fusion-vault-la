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
  factory.json
  vault_deployment.json
bot/
  context.py
  vault_state.py
  risk.py
  yields.py
  rebalance.py
  execute.py
  deploy.py
  report.py
scripts/
  vault_info.py
  propose_rebalance.py
  execute_rebalance.py
  report_allocations.py
  deploy_vault.py
docs/
  strategy.md
  operations.md
  risk-framework.md
  deployment.md
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

## Create a new vault

The `ipor-fusion` SDK only interacts with existing vaults, so a new Plasma Vault
is created on-chain by calling the IPOR Fusion `FusionFactory.clone(...)` method.
This is restricted to USDC underlying assets.

1. Set the official `FusionFactory` address for your chain in
   `config/factory.json` (the placeholder zero address is rejected). Find it via
   docs.ipor.io / the IPOR Discord.
2. Edit `config/vault_deployment.json` (chain, name, symbol, redemption delay).
3. Set `VAULT_OWNER_ADDRESS` in `.env`.

Dry run (predicts the new vault address via `eth_call`, sends nothing):

```bash
python scripts/deploy_vault.py
```

Live deployment after manual approval, registering the result into
`config/vaults.json`:

```bash
export OPERATOR_PRIVATE_KEY=0x...
python scripts/deploy_vault.py --execute --register
```

See `docs/deployment.md` for details.

## Safety rules

- USDC accounting/deposit asset only.
- Ethereum, Base, and Flare where supported.
- Morpho, Euler, and Superform/USDT0 only.
- Manual approval first.
- No leverage.
- No recursive loops.
- No unapproved routes.
- No private keys in repo.
