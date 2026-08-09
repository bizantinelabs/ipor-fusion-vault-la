"""Create (deploy) a new IPOR Fusion Plasma Vault via the FusionFactory.

The official ``ipor-fusion`` SDK only *interacts with* existing vaults; it has
no factory/deploy API. New vaults are created on-chain by calling the
``FusionFactory.clone(...)`` method from the IPOR Fusion contracts. This module
wraps that call with the same conservative, dry-run-first conventions used by
the rest of the operator bot (see ``bot/execute.py``):

- USDC accounting/deposit asset only.
- Live transactions require ``--execute`` plus ``OPERATOR_PRIVATE_KEY``.
- Placeholder (zero) factory addresses are refused.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from bot.context import (
    PROJECT_ROOT,
    ZERO_ADDRESS,
    ConfigurationError,
    load_env_file,
    read_json,
    require_real_address,
)

# Output tuple mirrors FusionFactoryLogicLib.FusionInstance so web3 can decode
# the address of the freshly created Plasma Vault returned by clone(...).
FUSION_INSTANCE_COMPONENTS = [
    {"name": "index", "type": "uint256"},
    {"name": "version", "type": "uint256"},
    {"name": "assetName", "type": "string"},
    {"name": "assetSymbol", "type": "string"},
    {"name": "assetDecimals", "type": "uint8"},
    {"name": "underlyingToken", "type": "address"},
    {"name": "underlyingTokenSymbol", "type": "string"},
    {"name": "underlyingTokenDecimals", "type": "uint8"},
    {"name": "initialOwner", "type": "address"},
    {"name": "plasmaVault", "type": "address"},
    {"name": "plasmaVaultBase", "type": "address"},
    {"name": "accessManager", "type": "address"},
    {"name": "feeManager", "type": "address"},
    {"name": "rewardsManager", "type": "address"},
    {"name": "withdrawManager", "type": "address"},
    {"name": "contextManager", "type": "address"},
    {"name": "priceManager", "type": "address"},
]

# Minimal ABI for the public permissionless creation method on FusionFactory.
FUSION_FACTORY_ABI = [
    {
        "type": "function",
        "name": "clone",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "assetName_", "type": "string"},
            {"name": "assetSymbol_", "type": "string"},
            {"name": "underlyingToken_", "type": "address"},
            {"name": "redemptionDelayInSeconds_", "type": "uint256"},
            {"name": "owner_", "type": "address"},
            {"name": "daoFeePackageIndex_", "type": "uint256"},
        ],
        "outputs": [
            {"name": "instance", "type": "tuple", "components": FUSION_INSTANCE_COMPONENTS},
        ],
    }
]

SUPPORTED_UNDERLYING = {"USDC"}
UNDERLYING_DECIMALS = {"USDC": 6}


@dataclass(frozen=True)
class DeploymentRequest:
    register_as: str
    chain: str
    asset_name: str
    asset_symbol: str
    underlying_asset: str
    redemption_delay_seconds: int
    owner: str
    underlying_token: str
    factory_address: str
    dao_fee_package_index: int
    rpc_env: str
    chain_id: int


def _checksum(address: str) -> str:
    from web3 import Web3

    return Web3.to_checksum_address(address)


def _resolve(path: str | Path) -> Path:
    resolved = Path(path)
    return resolved if resolved.is_absolute() else PROJECT_ROOT / resolved


def load_deployment_request(
    deployment_path: str | Path = "config/vault_deployment.json",
    factory_path: str | Path = "config/factory.json",
) -> DeploymentRequest:
    """Validate and resolve everything needed to call FusionFactory.clone(...)."""
    load_env_file()
    dep = read_json(deployment_path)
    factory_cfg = read_json(factory_path)

    chain = str(dep.get("chain") or "").strip()
    if not chain:
        raise ConfigurationError("vault_deployment.json must set 'chain'.")

    underlying = str(dep.get("underlying_asset") or "USDC").upper()
    if underlying not in SUPPORTED_UNDERLYING:
        raise ConfigurationError(
            f"This deployer is restricted to USDC underlying assets, got '{underlying}'."
        )

    factories = factory_cfg.get("factories", {})
    if chain not in factories:
        raise ConfigurationError(
            f"No FusionFactory configured for chain '{chain}' in {factory_path}."
        )
    chain_factory = factories[chain]
    factory_address = str(chain_factory.get("fusion_factory", ZERO_ADDRESS))
    require_real_address(factory_address, f"FusionFactory address for {chain}")

    tokens = factory_cfg.get("underlying_tokens", {}).get(underlying, {})
    token_address = str(tokens.get(chain, ZERO_ADDRESS))
    require_real_address(token_address, f"{underlying} token address for {chain}")

    owner_env = str(dep.get("owner_env") or "VAULT_OWNER_ADDRESS")
    owner = os.getenv(owner_env, "").strip()
    if not owner:
        raise ConfigurationError(f"Set {owner_env} to the vault owner address.")
    require_real_address(owner, "Vault owner address")

    asset_name = str(dep.get("asset_name") or "").strip()
    asset_symbol = str(dep.get("asset_symbol") or "").strip()
    if not asset_name or not asset_symbol:
        raise ConfigurationError(
            "vault_deployment.json must set 'asset_name' and 'asset_symbol'."
        )

    return DeploymentRequest(
        register_as=str(dep.get("register_as") or asset_symbol.lower()),
        chain=chain,
        asset_name=asset_name,
        asset_symbol=asset_symbol,
        underlying_asset=underlying,
        redemption_delay_seconds=int(dep.get("redemption_delay_seconds", 0)),
        owner=_checksum(owner),
        underlying_token=_checksum(token_address),
        factory_address=_checksum(factory_address),
        dao_fee_package_index=int(chain_factory.get("dao_fee_package_index", 0)),
        rpc_env=str(chain_factory.get("rpc_env") or f"{chain.upper()}_RPC_URL"),
        chain_id=int(chain_factory.get("chain_id", 0)),
    )


def _web3_for(request: DeploymentRequest, *, require_key: bool):
    from web3 import Web3

    rpc_url = os.getenv(request.rpc_env)
    if not rpc_url:
        raise ConfigurationError(f"Set {request.rpc_env} to an RPC URL for {request.chain}.")
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConfigurationError(f"Could not connect to the RPC URL in {request.rpc_env}.")

    account = None
    private_key = os.getenv("OPERATOR_PRIVATE_KEY")
    if require_key and not private_key:
        raise ConfigurationError(
            "Live deployment requires OPERATOR_PRIVATE_KEY in the environment."
        )
    if private_key:
        account = w3.eth.account.from_key(private_key)
    return w3, account


def _factory(w3, request: DeploymentRequest):
    return w3.eth.contract(address=request.factory_address, abi=FUSION_FACTORY_ABI)


def _clone_args(request: DeploymentRequest) -> tuple:
    return (
        request.asset_name,
        request.asset_symbol,
        request.underlying_token,
        request.redemption_delay_seconds,
        request.owner,
        request.dao_fee_package_index,
    )


def _decode_instance(values: Any) -> dict[str, Any]:
    keys = [component["name"] for component in FUSION_INSTANCE_COMPONENTS]
    return dict(zip(keys, values))


def _tx_preview(request: DeploymentRequest) -> dict[str, Any]:
    return {
        "to": request.factory_address,
        "function": "clone",
        "args": {
            "assetName": request.asset_name,
            "assetSymbol": request.asset_symbol,
            "underlyingToken": request.underlying_token,
            "redemptionDelayInSeconds": request.redemption_delay_seconds,
            "owner": request.owner,
            "daoFeePackageIndex": request.dao_fee_package_index,
        },
    }


def simulate_deploy(request: DeploymentRequest) -> dict[str, Any]:
    """Statically call clone(...) (eth_call) to predict the new vault address."""
    w3, account = _web3_for(request, require_key=False)
    fn = _factory(w3, request).functions.clone(*_clone_args(request))
    raw = fn.call({"from": account.address}) if account is not None else fn.call()
    instance = _decode_instance(raw)
    return {
        "predicted_plasma_vault": instance.get("plasmaVault"),
        "instance": instance,
        "factory": request.factory_address,
        "chain": request.chain,
    }


def deploy_vault(request: DeploymentRequest, *, execute: bool = False) -> dict[str, Any]:
    """Deploy a new Plasma Vault. Dry run unless ``execute`` is True."""
    preview = simulate_deploy(request)
    tx_preview = _tx_preview(request)

    if not execute:
        return {
            "executed": False,
            "reason": (
                "Dry run only. Re-run with --execute and OPERATOR_PRIVATE_KEY "
                "after manual approval."
            ),
            "tx_preview": tx_preview,
            **preview,
        }

    w3, account = _web3_for(request, require_key=True)
    factory = _factory(w3, request)
    fn = factory.functions.clone(*_clone_args(request))
    tx = fn.build_transaction(
        {
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "chainId": request.chain_id or w3.eth.chain_id,
        }
    )
    signed = account.sign_transaction(tx)
    raw_tx = getattr(signed, "raw_transaction", None)
    if raw_tx is None:  # web3.py < 7 used rawTransaction
        raw_tx = signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if int(receipt.get("status", 0)) != 1:
        raise ConfigurationError(f"FusionFactory.clone transaction reverted: {tx_hash.hex()}")

    # Reproduce the exact pre-transaction state to read the real vault address
    # the factory assigned (clone addresses are sequential, so re-running the
    # static call at the prior block is authoritative).
    instance = preview["instance"]
    plasma_vault = preview["predicted_plasma_vault"]
    try:
        block = int(receipt["blockNumber"]) - 1
        instance = _decode_instance(fn.call({"from": account.address}, block_identifier=block))
        plasma_vault = instance.get("plasmaVault", plasma_vault)
    except Exception:
        pass  # keep the pre-send prediction if historical eth_call is unavailable

    return {
        "executed": True,
        "transaction_hash": tx_hash.hex(),
        "plasma_vault": plasma_vault,
        "instance": instance,
        "tx_preview": tx_preview,
        "chain": request.chain,
    }


def register_deployed_vault(
    request: DeploymentRequest,
    plasma_vault: str,
    *,
    path: str | Path = "config/vaults.json",
) -> dict[str, Any]:
    """Write the newly created vault into config/vaults.json so the operator
    bot can target it. Non-destructive: other vaults are preserved."""
    require_real_address(plasma_vault, "Deployed Plasma Vault address")
    resolved = _resolve(path)
    data = read_json(path)

    chains = data.setdefault("chains", {})
    chains.setdefault(
        request.chain,
        {"chain_id": request.chain_id, "rpc_env": request.rpc_env, "supported": True},
    )

    entry = {
        "name": request.asset_name,
        "accounting_asset": request.underlying_asset,
        "accounting_asset_decimals": UNDERLYING_DECIMALS.get(request.underlying_asset, 18),
        "chain": request.chain,
        "chain_id": request.chain_id,
        "address": _checksum(plasma_vault),
        "rpc_env": request.rpc_env,
        "current_allocations_bps": {"idle": 10000},
    }
    data.setdefault("vaults", {})[request.register_as] = entry

    with resolved.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    return entry


def request_summary(request: DeploymentRequest) -> dict[str, Any]:
    return asdict(request)
