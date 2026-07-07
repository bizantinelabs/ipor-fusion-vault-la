# broadcast.md — Bizantine cbBase USDC CORE (Base 8453)

Push-button fork-sim → broadcast → verify runbook. Every `cast`/`forge` command below is
grounded in the real `ipor-fusion` interfaces (getters verified in `IPlasmaVaultGovernance`,
`IporFusionAccessManager`, `FeeManager`, `WithdrawManager`). Run top to bottom. **Do not run
step 5 (broadcast) until steps 0–4 pass.**

> Correction vs. the original brief: `forge script` forks from `--rpc-url` alone. There is no
> `--fork-url` flag for `forge script` (that's `forge test`/`anvil`). Commands below use `--rpc-url`.

---

## 0. Prerequisites

```bash
# Toolchain
foundryup                      # forge + cast; repo pins solc 0.8.30 (auto-resolved by forge)
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/XXXX"   # your Base RPC
export ETHERSCAN_API_KEY="XXXX"                                    # Basescan key (--verify)
export DEPLOYER="0xYourDeployerEOA"                                # must match the keystore below
```

Signer: use a keystore/hardware wallet — **never** a raw key on the CLI.
```bash
# one-time import (interactive; encrypted keystore, no plaintext key on disk)
cast wallet import cbbase-deployer --interactive
# ...or use --ledger / --trezor in place of --account below
```

Gate (must all be true — this is the §0 pre-flight; the deploy `require()`s enforce most of them):
```bash
# fill every slot in script/DeployCbBaseUsdcCore.s.sol, then confirm none remain:
grep -nE "address\(0\)|type\(uint256\)\.max|WITHDRAW_WINDOW_SECONDS = 0" \
  script/DeployCbBaseUsdcCore.s.sol
# EXPECT: no matches. Any hit = gate NOT green, stop.
```
Also confirm (not machine-checkable here): Option A fuse instances are the real per-marketId
deployments from IPOR; Alpha + Guardian accounts received; `daoFeePackageIndex` + DAO fee split
set so on-chain totals = 10% perf / 0.5% mgmt; Owner/Atomist Safes controllable **on Base**.

## 1. Repo setup (work inside a clone of IPOR-Labs/ipor-fusion)

```bash
git clone https://github.com/IPOR-Labs/ipor-fusion.git
cd ipor-fusion
git submodule update --init --recursive          # forge-std etc.
npm install                                       # @openzeppelin/@uniswap/pendle/EVC (remappings)
mkdir -p script config
cp /path/to/cbbase-usdc-core-deploy/script/DeployCbBaseUsdcCore.s.sol script/
cp /path/to/cbbase-usdc-core-deploy/config/cbbase_usdc_core.json     config/
```

## 2. Compile

```bash
forge build
# EXPECT: compiles clean. Resolve any error against the real repo (never stub a symbol).
```

## 3. Fork simulation (NO broadcast — dry run against live Base state)

```bash
forge script script/DeployCbBaseUsdcCore.s.sol:DeployCbBaseUsdcCore \
  --rpc-url "$BASE_RPC_URL" \
  --sender "$DEPLOYER" \
  -vvvv
```
PASS criteria:
- The whole `run()` sequence executes with **no revert** (clone → temp-role grants → fuses →
  substrates → dependency graph → limits+activate → oracle → instant-withdraw → window → fees →
  production roles → deployer role revokes).
- Logged addresses appear: `plasmaVault / accessManager / feeManager / withdrawManager / priceManager`.
- If any config call reverts, re-check the role/ordering assumptions — do **not** patch by loosening roles.

## 4. Same-day liquidity re-check (rates/liquidity move)

Re-pull the 6 Morpho markets + Compound/Aave and enforce **available liquidity ≥ 3× target position**
before allowlisting. Prior read (2026-07-07) flagged thin legs: cbLTC ~$86K, cbADA ~$190K,
cbDOGE ~$242K, cbETH ~$0.59M (cbETH is a T1 instant-withdraw leg). If a leg fails 3×, cut its target
or hold it out until liquidity recovers.
```bash
# via the IPOR MCP server (mcp.ipor.io) tool market_morpho_blue for each id, or Morpho API:
#   query markets(where:{uniqueKey_in:[...6 ids...], chainId_in:[8453]}){ items{ marketId
#     loanAsset{symbol address} collateralAsset{symbol}
#     state{ supplyApy utilization liquidityAssetsUsd supplyAssetsUsd } } }
```

## 5. Broadcast (IRREVERSIBLE — name/symbol/asset/fees immutable after clone)

```bash
forge script script/DeployCbBaseUsdcCore.s.sol:DeployCbBaseUsdcCore \
  --rpc-url "$BASE_RPC_URL" \
  --account cbbase-deployer --sender "$DEPLOYER" \
  --broadcast --slow \
  --verify --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --chain 8453 \
  -vvvv
```
Notes:
- `--slow` sends txs one at a time (safer nonce handling for the multi-step sequence).
- `--account`/`--sender` must resolve to the same EOA the script clones with (`vm.readCallers()`).
- Hardware wallet: swap `--account … --sender …` for `--ledger` (or `--trezor`).
- If Basescan verification flakes, re-verify later (deploy state is unaffected):
  `forge verify-contract <addr> <Contract> --chain 8453 --etherscan-api-key "$ETHERSCAN_API_KEY"`.

## 6. Capture deployed addresses

```bash
RUN=broadcast/DeployCbBaseUsdcCore.s.sol/8453/run-latest.json
# clone() is the first tx; its return + the console2 logs carry the instance addresses.
jq -r '.transactions[] | select(.transactionType=="CALL" or .transactionType=="CREATE")
       | [.transactionType, .contractName, .contractAddress] | @tsv' "$RUN" | head
# Prefer the console2 logs printed in step 5 (plasmaVault/accessManager/feeManager/withdrawManager/priceManager).
# Record all six into config/ and spec §13.
export VAULT=0x...   AM=0x...   FEE=0x...   WM=0x...   PM=0x...
```

## 7. On-chain verification (maps to VERIFY.md; all getters are real)

```bash
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
# --- Identity (immutable) ---
cast call $VAULT "name()(string)"     --rpc-url "$BASE_RPC_URL"   # "Bizantine cbBase USDC CORE"
cast call $VAULT "symbol()(string)"   --rpc-url "$BASE_RPC_URL"   # "bizcbBaseUSDC"
cast call $VAULT "asset()(address)"   --rpc-url "$BASE_RPC_URL"   # == $USDC

# --- Fuses & substrates ---
cast call $VAULT "getFuses()(address[])" --rpc-url "$BASE_RPC_URL"          # 8 supply fuses
for m in 1 2 3 4 5 6 10 11 7; do
  echo -n "market $m substrates: "
  cast call $VAULT "getMarketSubstrates(uint256)(bytes32[])" $m --rpc-url "$BASE_RPC_URL"
done

# --- Caps (1e18 = 100%) + protection ACTIVE ---
cast call $VAULT "isMarketsLimitsActivated()(bool)" --rpc-url "$BASE_RPC_URL"   # true
for m in 1 2 3 4 5 6 10 11; do
  echo -n "cap $m: "; cast call $VAULT "getMarketLimit(uint256)(uint256)" $m --rpc-url "$BASE_RPC_URL"
done
# EXPECT (wei-1e18): 1=5e17 2=25e16 3=22e16 4=8e16 5=6e16 6=5e16 10=2e17 11=25e16

# --- Instant-withdraw order (idle→Aave→Compound→cbBTC→cbETH; T2/3 excluded) ---
cast call $VAULT "getInstantWithdrawalFuses()(address[])" --rpc-url "$BASE_RPC_URL"  # [Aave,Compound,cbBTC,cbETH]

# --- Roles (hasRole -> (isMember,executionDelay)) ---
AM_HAS() { cast call $AM "hasRole(uint64,address)(bool,uint32)" $1 $2 --rpc-url "$BASE_RPC_URL"; }
AM_HAS 1   $OWNER_SAFE     # OWNER, delay 0
AM_HAS 100 $ATOMIST_SAFE   # ATOMIST, delay 86400 (or 172800)
AM_HAS 200 $ALPHA_IPOR     # ALPHA, delay 0
AM_HAS 2   $GUARDIAN_HN    # GUARDIAN, delay 0
AM_HAS 600 $ALPHA_IPOR     # CLAIM_REWARDS
AM_HAS 700 $ALPHA_IPOR     # TRANSFER_REWARDS
AM_HAS 900 $ATOMIST_SAFE   # CONFIG_INSTANT_WITHDRAWAL (Atomist, not Alpha)
# Deployer temp roles must be GONE (all false):
for r in 1 100 300 900 1200; do echo -n "deployer role $r: "; AM_HAS $r $DEPLOYER; done

# --- Oracle / fees / withdrawals ---
cast call $VAULT "getPriceOracleMiddleware()(address)" --rpc-url "$BASE_RPC_URL"   # non-zero
cast call $FEE  "getTotalPerformanceFee()(uint256)"    --rpc-url "$BASE_RPC_URL"   # 1000 (=10.00%, 2dp)
cast call $FEE  "getTotalManagementFee()(uint256)"     --rpc-url "$BASE_RPC_URL"   # 50   (=0.50%)
cast call $WM   "getWithdrawWindow()(uint256)"         --rpc-url "$BASE_RPC_URL"   # > 0
```
Then run the **negative tests** and **Guardian dry-run** from `VERIFY.md` (Alpha cannot
addFuses/grantMarketSubstrates/setupMarketsLimits/updateFee/grantRole or move assets externally;
Guardian pause→force-exit-to-buffer→unpause works independent of the Alpha key).

## 8. Open the vault (only after VERIFY is fully green)

Vault ships **private** (deposits blocked). When ops signs off, the **Atomist Safe** (subject to its
timelock) runs:
```
PlasmaVaultGovernance(vault).convertToPublicVault();   // ATOMIST_ROLE
PlasmaVaultGovernance(vault).enableTransferShares();   // ATOMIST_ROLE
```
Seed anchor TVL, confirm NAV/share math, then a small test rebalance across legs (incl. T2/3) to
confirm the cap gates fire correctly against live liquidity.

## Abort / rollback
- **Before step 5:** nothing on-chain — just fix inputs and re-sim.
- **A tx reverts mid-broadcast:** the vault exists (clone succeeded) but is partially configured and
  the deployer still holds temp roles. Do **not** open it. Diagnose the revert, then either re-run the
  remaining config as the deployer (it still has ATOMIST/FUSE_MANAGER/CONFIG_INSTANT until the step-10
  revokes) or, if unrecoverable, abandon the instance and redeploy — clone is cheap; a misconfigured
  vault is not fixable for immutables (name/symbol/asset/fees-at-clone).
```
