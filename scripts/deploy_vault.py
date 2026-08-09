#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bot.deploy import deploy_vault, load_deployment_request, register_deployed_vault
from bot.report import to_json


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Create (deploy) a new IPOR Fusion Plasma Vault via the FusionFactory. "
            "Defaults to a dry run that predicts the new vault address without "
            "sending a transaction."
        )
    )
    parser.add_argument(
        "--config",
        default="config/vault_deployment.json",
        help="Path to the vault deployment config.",
    )
    parser.add_argument(
        "--factory-config",
        default="config/factory.json",
        help="Path to the FusionFactory address config.",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Send the live deployment transaction. Requires OPERATOR_PRIVATE_KEY.",
    )
    parser.add_argument(
        "--register",
        action="store_true",
        help="On a successful live deployment, write the new vault into config/vaults.json.",
    )
    args = parser.parse_args()

    request = load_deployment_request(args.config, args.factory_config)
    result = deploy_vault(request, execute=args.execute)

    registered = None
    if args.execute and result.get("executed"):
        plasma_vault = result.get("plasma_vault") or result.get("predicted_plasma_vault")
        if args.register and plasma_vault:
            registered = register_deployed_vault(request, plasma_vault)

    print(
        to_json(
            {
                "request": {
                    "register_as": request.register_as,
                    "chain": request.chain,
                    "asset_name": request.asset_name,
                    "asset_symbol": request.asset_symbol,
                    "underlying_asset": request.underlying_asset,
                    "owner": request.owner,
                    "factory": request.factory_address,
                },
                "result": result,
                "registered": registered,
            }
        )
    )


if __name__ == "__main__":
    main()
