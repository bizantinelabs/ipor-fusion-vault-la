// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

interface IUniswapV3PoolMinimal {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title PrepareTwapObservations
/// @notice Starts the Uniswap V3 TWAP observation buffer on the FXRP/RLUSD pool.
///
/// WHY THIS IS THE FIRST THING THAT SHOULD RUN
/// ------------------------------------------
/// Measured on mainnet 2026-08-09, the pool reports:
///     observationCardinality     = 1
///     observationCardinalityNext = 1
/// i.e. nobody has ever called increaseObservationCardinalityNext. With cardinality 1 the pool
/// stores exactly one observation, so `observe([900, 0])` does NOT revert — it silently returns a
/// figure derived from that single datapoint. Demonstrated directly: the tick computed from a
/// nominal 900-second TWAP came back BIT-FOR-BIT IDENTICAL to the spot tick from slot0()
/// (-276722 in both cases).
///
/// So `FXRPPriceFeedEthereum` deployed against this pool today would produce a feed that LOOKS
/// manipulation-resistant and is in fact pure spot price. That is the silent-failure mode the peg
/// guard exists to prevent.
///
/// Fixing it requires two things, and only the first is a transaction:
///     1. call increaseObservationCardinalityNext(N)  <- this script
///     2. WAIT. The ring buffer must physically fill with observations spanning TWAP_WINDOW
///        before any TWAP read is trustworthy. Slots are written at most once per block and ONLY
///        when the pool is touched by a swap/mint/burn. This pool trades thinly (~$84k/24h at last
///        snapshot), so filling is driven by trade arrival, not by block production — expect this
///        to take meaningfully longer than 900 seconds of wall clock.
///
/// This is the longest-lead item in the entire project and it needs no audit, no governance vote,
/// and no custom contract. It should be started immediately, ahead of everything else.
///
/// CHOOSING N
/// ----------
/// Worst case is one observation written per block. Ethereum ~12s blocks => 900s / 12s = 75 slots
/// to guarantee a 900-second window even if the pool were traded every single block. N=150 gives
/// ~2x headroom and allows raising TWAP_WINDOW later without re-growing the buffer.
///
/// Cost is not a constraint here. Each new slot is a cold SSTORE (~20k gas). Measured at the time
/// of writing (gas price 0.07 gwei):
///     N=75  -> ~1.55M gas ~= 0.0001 ETH
///     N=100 -> ~2.05M gas ~= 0.0001 ETH
///     N=150 -> ~3.05M gas ~= 0.0002 ETH
/// Re-check gas price before broadcasting; the ETH figures above assume an unusually cheap moment.
///
/// PERMISSIONLESS: increaseObservationCardinalityNext has no access control. ANY funded EOA can
/// call it. It does not require the vault's keys, the Governance Safe, or any vault role, and it
/// grants the caller no privileges over the pool or the vault. This is the one blocker on the
/// critical path that can be cleared without touching vault custody at all.
contract PrepareTwapObservations is Script {
    address constant POOL = 0x42271FcA1FA435B176D46a5544B2698a1E261782; // FXRP/RLUSD 0.3%
    uint16 constant TARGET_CARDINALITY = 150;

    /// @notice Read-only inspection. Run this first, and again periodically while waiting.
    ///         forge script script/PrepareTwapObservations.s.sol:PrepareTwapObservations \
    ///           --sig "check()" --rpc-url $RPC
    function check() external view {
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(POOL);
        (, int24 spotTick, uint16 idx, uint16 card, uint16 cardNext, , ) = pool.slot0();

        console2.log("observationIndex          ", uint256(idx));
        console2.log("observationCardinality    ", uint256(card));
        console2.log("observationCardinalityNext", uint256(cardNext));
        console2.log("spot tick (slot0)         ", int256(spotTick));

        // Compare a nominal 900s TWAP against spot. If these are equal, the buffer has NOT filled
        // and the "TWAP" is just spot — do not deploy the price feed yet.
        uint32[] memory ago = new uint32[](2);
        ago[0] = 900;
        ago[1] = 0;
        try pool.observe(ago) returns (int56[] memory cums, uint160[] memory) {
            int56 delta = cums[1] - cums[0];
            int24 twapTick = int24(delta / int56(uint56(900)));
            if (delta < 0 && (delta % int56(uint56(900)) != 0)) twapTick--;
            console2.log("900s TWAP tick            ", int256(twapTick));
            if (twapTick == spotTick) {
                console2.log(">>> TWAP TICK == SPOT TICK. Buffer not filled. DO NOT deploy the price feed.");
            } else {
                console2.log(">>> TWAP diverges from spot - buffer is accumulating real history.");
            }
        } catch {
            console2.log(">>> observe([900,0]) REVERTED - insufficient history.");
        }
    }

    /// @notice Broadcasts increaseObservationCardinalityNext(TARGET_CARDINALITY).
    ///         Permissionless; any funded EOA can send it.
    function run() external {
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(POOL);
        (, , , uint16 card, uint16 cardNext, , ) = pool.slot0();
        console2.log("before: cardinality", uint256(card), "next", uint256(cardNext));

        if (cardNext >= TARGET_CARDINALITY) {
            console2.log("cardinalityNext already >= target; nothing to do. Still need to WAIT for fill.");
            return;
        }

        vm.startBroadcast();
        pool.increaseObservationCardinalityNext(TARGET_CARDINALITY);
        vm.stopBroadcast();

        (, , , uint16 cardAfter, uint16 cardNextAfter, , ) = pool.slot0();
        console2.log("after : cardinality", uint256(cardAfter), "next", uint256(cardNextAfter));
        console2.log("NOTE: cardinality itself only grows as trades arrive. Re-run check() over the");
        console2.log("      coming days until the 900s TWAP tick diverges from the spot tick.");
    }
}
