# Vault deployment

This repository uses the official `ipor-fusion` Python SDK to operate an
existing Plasma Vault. The SDK does **not** deploy vaults, so creating a new
vault is done by calling the IPOR Fusion `FusionFactory` contract directly with
`web3`.

## How it works

`scripts/deploy_vault.py` → `bot/deploy.py` calls:

```solidity
function clone(
    string  assetName_,
    string  assetSymbol_,
    address underlyingToken_,
    uint256 redemptionDelayInSeconds_,
    address owner_,
    uint256 daoFeePackageIndex_
) external returns (FusionInstance memory)
```

`FusionInstance.plasmaVault` is the address of the newly created vault. The tool
first performs an `eth_call` (no transaction) to predict that address. With
`--execute`, it signs and sends the real `clone(...)` transaction, waits for the
receipt, and re-reads the address from the pre-transaction block to report the
exact deployed vault.

## Configuration

- `config/factory.json`
  - `factories.<chain>.fusion_factory` — the official FusionFactory address
    (placeholder `0x000…0` is refused). Source it from docs.ipor.io / IPOR Discord.
  - `factories.<chain>.dao_fee_package_index` — DAO fee package selector.
  - `underlying_tokens.USDC.<chain>` — canonical USDC address (prefilled for
    Ethereum, Base, Arbitrum).
- `config/vault_deployment.json` — `chain`, `asset_name`, `asset_symbol`,
  `underlying_asset` (USDC only), `redemption_delay_seconds`, `owner_env`,
  `register_as`.
- `.env` — `<CHAIN>_RPC_URL`, `VAULT_OWNER_ADDRESS`, and (for `--execute`)
  `OPERATOR_PRIVATE_KEY`.

## Safety

- USDC underlying only.
- Dry run by default; live transactions require `--execute` **and**
  `OPERATOR_PRIVATE_KEY`.
- A placeholder/zero factory or token address aborts with a clear error.
- Private keys are read from the environment and must never be committed.

## Commands

```bash
# Dry run — predict the vault address, send nothing
python scripts/deploy_vault.py

# Live deploy and register into config/vaults.json
export OPERATOR_PRIVATE_KEY=0x...
python scripts/deploy_vault.py --execute --register
```

After registration the new vault is available to the operator scripts, e.g.:

```bash
python scripts/vault_info.py --vault bizantine_usdc_vault
```
