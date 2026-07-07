# IPOR Fusion MCP integration

This repository registers the official IPOR Fusion MCP server so that
Claude Code (and any other MCP-capable client) can query **live**
IPOR Fusion vault, deployment, and Morpho market data while working in
this repo.

## What is configured

The project-scoped config lives in [`.mcp.json`](../.mcp.json) at the repo
root:

```json
{
  "mcpServers": {
    "ipor-fusion": {
      "type": "http",
      "url": "https://mcp.ipor.io/"
    }
  }
}
```

- **Transport:** streamable HTTP (`https://mcp.ipor.io/`)
- **Auth:** none required (read-only, public data)
- **Server:** `ipor-fusion-dev`

## How to enable it

### Claude Code

`.mcp.json` is picked up automatically. On first use Claude Code prompts
once to approve the project-scoped server; approve it, then check status:

```bash
claude mcp list
# ipor-fusion  ✓ connected
```

You can also add it explicitly (equivalent to the file above):

```bash
claude mcp add --transport http ipor-fusion https://mcp.ipor.io/
```

### Other clients (Cursor, Claude Desktop, etc.)

Point the client at the same streamable-HTTP URL, `https://mcp.ipor.io/`.

## Available tools

The server exposes read-only tools that return JSON:

| Tool | Purpose |
| --- | --- |
| `vault_info` | Full on-chain state of a Plasma Vault (same JSON as `fusion vault info --json`). Args: `vault_address`, `chain_id`, `block_number`. |
| `vaults_list` | All IPOR Fusion vaults from the public API — APY, TVL, assets, TVL. APY fields are pre-formatted percent strings (e.g. `"4.30%"`); render verbatim. |
| `fusion_addresses_list` | Full `{ContractName: address}` deployment map for a chain. |
| `fusion_address_names` | Contract names available in the deployment files (per chain or cross-chain union). |
| `fusion_address_lookup` | Resolve a contract by name substring or by address across deployments. |
| `market_morpho_blue` | Inspect a Morpho Blue market by 32-byte market ID — params, state, and APYs. Rates are fractions (0.0436 = 4.36%). |
| `market_meta_morpho` | Inspect a MetaMorpho V1 / Morpho Vault V2 by address via the Morpho API. |

## Relationship to the operator bot

The Python operator bot in [`bot/`](../bot) reads vault and market data
directly through the `ipor-fusion` SDK over an RPC endpoint. The MCP
server is a **complementary, read-only** surface: it returns the same
`vault_info` JSON without requiring a local RPC URL, which makes it useful
for interactive inspection and for AI-assisted analysis of vault state and
rebalance decisions. It does not execute transactions and does not replace
the bot's SDK-based execution path.
