#!/usr/bin/env bash
# Measure FXRP/RLUSD pool depth at 1% and 5% execution slippage, both directions,
# and derive the bzFXRP-ETH supply cap.
#
# Read-only. Uses QuoterV2 via eth_call (simulated, no transaction, no key required).
#
# Per bizFXRP-ETH_FULL_SPEC.md §12:
#     max_vault_FXRP = depth_at_5%_slippage / (hardMaxLTV * stressMultiple)
#                    = depth_at_5% / (0.40 * 3)
# and per the v2 deployment package: "Use the WORSE of the two directions."
#
# Usage:  RPC=https://... ./measure_depth.sh
#
# Re-run this immediately before setting the on-chain supply cap. Depth is a point-in-time
# property of a young, thin pool and can change materially between measurement and deployment.

set -euo pipefail

RPC="${RPC:-https://ethereum-rpc.publicnode.com}"
QUOTER=0x61fFE014bA17989E743c5F6cB21bF9697530B21e   # Uniswap V3 QuoterV2, Ethereum mainnet
FXRP=0xCE6170EA245dC8D1f275A710a062b70f125F0110     # 6 decimals
RLUSD=0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD    # 18 decimals
POOL=0x42271FcA1FA435B176D46a5544B2698a1E261782     # FXRP/RLUSD 0.3%
FEE=3000

q_fxrp_in()  { cast call "$QUOTER" "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
                 "($FXRP,$RLUSD,$1,$FEE,0)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }
q_rlusd_in() { cast call "$QUOTER" "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
                 "($RLUSD,$FXRP,$1,$FEE,0)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }

echo "=== pool reserves ==="
FB=$(cast call "$FXRP"  "balanceOf(address)(uint256)" "$POOL" --rpc-url "$RPC" | awk '{print $1}')
RB=$(cast call "$RLUSD" "balanceOf(address)(uint256)" "$POOL" --rpc-url "$RPC" | awk '{print $1}')
python3 -c "print(f'  FXRP : {$FB/1e6:,.0f}'); print(f'  RLUSD: {$RB/1e18:,.0f}')"

echo
echo "=== observation cardinality (TWAP readiness) ==="
# cast prints one value per line and appends a [sci-notation] annotation to large numbers,
# so strip the annotations first and index by line rather than by whitespace field.
mapfile -t SLOT0 < <(cast call "$POOL" "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" \
  --rpc-url "$RPC" | sed 's/ \[.*\]//')
echo "  observationIndex       = ${SLOT0[2]}"
echo "  cardinality            = ${SLOT0[3]}"
echo "  cardinalityNext        = ${SLOT0[4]}"
if [ "${SLOT0[3]}" = "1" ]; then
  echo "  >>> cardinality 1 => NO TWAP history. Any TWAP read is spot price."
  echo "  >>> See PrepareTwapObservations.s.sol - this is the longest-lead blocker."
fi

# spot reference: smallest meaningful clip
SPOT_A=$(q_fxrp_in 1000000)                 # 1 FXRP
SPOT_B=$(q_rlusd_in 1000000000000000000)    # 1 RLUSD

echo
echo "=== direction A: FXRP -> RLUSD  (exit / delever direction) ==="
printf "  %12s  %14s  %10s\n" "FXRP_in" "px/FXRP" "deviation"
for amt in 1000 10000 50000 100000 150000 200000 400000 600000 780000 800000 820000 900000; do
  out=$(q_fxrp_in $((amt * 1000000))) || continue
  [ -z "$out" ] && continue
  python3 -c "
px=($out/1e18)/$amt; spot=$SPOT_A/1e18
print(f'  {$amt:>12,}  {px:>14.6f}  {(px/spot-1)*100:>+9.3f}%')"
done

echo
echo "=== direction B: RLUSD -> FXRP  (entry direction) ==="
printf "  %12s  %14s  %10s\n" "RLUSD_in" "FXRP/RLUSD" "deviation"
for amt in 1000 10000 50000 100000 200000 400000 600000 800000; do
  raw=$(python3 -c "print($amt*10**18)")
  out=$(q_rlusd_in "$raw") || continue
  [ -z "$out" ] && continue
  python3 -c "
px=($out/1e6)/$amt; spot=$SPOT_B/1e6
print(f'  {$amt:>12,}  {px:>14.6f}  {(px/spot-1)*100:>+9.3f}%')"
done

cat <<'NOTE'

=== interpreting this ===
Find the input size where deviation crosses -1% and -5% in EACH direction. Convert direction B's
crossover to FXRP-equivalent (use its FXRP_out). Take the WORSE (smaller) of the two 5% figures,
then:

    supply_cap_FXRP = depth_at_5%_worse_direction / 1.2

Caveats that belong in the governance record alongside any number this produces:
  * Point-in-time. A single measurement of a young, thin pool.
  * QuoterV2 simulates against current state. Real execution faces MEV, sandwiching, and
    concurrent flow; achieved slippage will be worse than quoted.
  * Concentrated liquidity can be withdrawn. Check LP concentration before trusting depth to
    persist -- a single LP exiting can remove most of it.
  * 5% slippage is itself a severe execution assumption for an emergency delever. The
    stressMultiple of 3 in the spec formula is what absorbs that; do not also relax it.
NOTE
