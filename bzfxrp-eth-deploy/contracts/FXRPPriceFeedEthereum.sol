// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "./vendor/OracleLibrary.sol"; // 0.8-compatible vendored copy

interface IMorphoOracle {
    /// @return price scaled by 1e36 * 10**loanDecimals / 10**collateralDecimals
    function price() external view returns (uint256);
}

/// @title FXRPPriceFeedEthereum
/// @notice Dual-mark FXRP oracle for bzFXRP-ETH.
///
/// @dev Two marks, deliberately. Identical in normal conditions; they diverge exactly
///      when it matters.
///
///      ── LTV MARK ──  morphoPrice() / collateralValueInLoanToken() / ltvBps()
///      Direct passthrough of the live Morpho oracle for FXRP/RLUSD. Read by the LTV
///      pre-hook. Computing LTV from any other source would measure something Morpho
///      does not liquidate on — a 40% ceiling against a different denominator is not
///      a ceiling. Morpho market params are immutable, so MORPHO_ORACLE is fixed for
///      the life of the market; reading it rather than replicating its arithmetic
///      removes replication risk entirely.
///
///      ── NAV MARK ──  latestRoundData()
///      Conservative and peg-aware. Registered in Fusion's PriceOracleMiddleware for
///      share pricing:
///
///          answer = max( floor , min( redstoneXrpUsd , dexImpliedFxrpUsd ) )
///          floor  = redstoneXrpUsd * (1 - MAX_DISCOUNT_BPS)
///
/// @dev WHY THEY MUST DIFFER. The live Morpho oracle
///      0x5AC03061500E0C97862a466a38a7e87FAC4Ac39D is BASE_FEED_1 (RedStone XRP)
///      divided by QUOTE_FEED_1 (Chainlink RLUSD/USD), with BASE_VAULT and
///      QUOTE_VAULT unset. It carries NO FAssets, bridge, or DEX component — it
///      prices bridged FXRP as if it were native XRP.
///
///      So on an FXRP depeg Morpho keeps marking collateral at par and does not
///      liquidate. The vault is therefore not at liquidation risk from a depeg alone
///      — but its LPs hold an impaired asset, and reporting it at par would be false.
///      The NAV mark writes it down; the LTV mark does not. That divergence is the
///      intended behaviour, not an inconsistency to reconcile.
///
/// @dev Chainlink publishes no XRP feed on Ethereum — 0 of 290 mainnet feeds. The
///      RedStone push feed is the only XRP price in this stack, for Morpho and for
///      this vault. Treat its liveness as a single point of failure.
contract FXRPPriceFeedEthereum is AggregatorV3Interface {
    /* ───────────────────────────── immutables ───────────────────────────── */

    /// @notice RedStone XRP/USD push feed, 8dp. Morpho's BASE_FEED_1.
    AggregatorV3Interface public immutable XRP_USD;
    /// @notice Chainlink RLUSD/USD, 8dp. Morpho's QUOTE_FEED_1.
    AggregatorV3Interface public immutable RLUSD_USD;
    /// @notice Live Morpho oracle for FXRP/RLUSD. Immutable per market params.
    IMorphoOracle public immutable MORPHO_ORACLE;

    /// @notice Uniswap V3 FXRP/RLUSD pool — the peg reference
    IUniswapV3Pool public immutable POOL;
    address public immutable FXRP;
    address public immutable RLUSD;

    uint256 public immutable MAX_STALENESS;
    uint32 public immutable TWAP_WINDOW;
    /// @notice Largest discount to XRP the NAV mark will track, bps
    uint256 public immutable MAX_DISCOUNT_BPS;
    /// @notice Deviation past which isPegHealthy() goes false, bps
    uint256 public immutable PEG_TOLERANCE_BPS;

    uint256 private constant BPS = 10_000;
    /// @notice Morpho's ORACLE_PRICE_SCALE
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    error StalePrice(uint256 updatedAt, uint256 maxStaleness);
    error InvalidPrice(int256 answer);
    error NoHistoricalRounds();

    constructor(
        address xrpUsdFeed_,
        address rlusdUsdFeed_,
        address morphoOracle_,
        address pool_,
        address fxrp_,
        address rlusd_,
        uint256 maxStaleness_,
        uint32 twapWindow_,
        uint256 maxDiscountBps_,
        uint256 pegToleranceBps_
    ) {
        XRP_USD = AggregatorV3Interface(xrpUsdFeed_);
        RLUSD_USD = AggregatorV3Interface(rlusdUsdFeed_);
        MORPHO_ORACLE = IMorphoOracle(morphoOracle_);
        POOL = IUniswapV3Pool(pool_);
        FXRP = fxrp_;
        RLUSD = rlusd_;
        MAX_STALENESS = maxStaleness_;
        TWAP_WINDOW = twapWindow_;
        MAX_DISCOUNT_BPS = maxDiscountBps_;
        PEG_TOLERANCE_BPS = pegToleranceBps_;
    }

    /* ══════════════════════════════ LTV MARK ══════════════════════════════ */

    /// @notice Live Morpho price, RLUSD per FXRP, scaled 1e36 * 1e18 / 1e6 = 1e48.
    function morphoPrice() public view returns (uint256) {
        return MORPHO_ORACLE.price();
    }

    /// @notice Collateral value in loan-token (RLUSD) units, using Morpho's arithmetic.
    /// @param fxrpAmount FXRP in native 6dp units
    /// @return RLUSD-denominated value, 18dp
    function collateralValueInLoanToken(uint256 fxrpAmount) public view returns (uint256) {
        return (fxrpAmount * morphoPrice()) / ORACLE_PRICE_SCALE;
    }

    /// @notice Position LTV in bps, computed exactly as Morpho would.
    /// @param fxrpCollateral FXRP collateral, 6dp
    /// @param rlusdBorrowed  RLUSD debt, 18dp
    function ltvBps(uint256 fxrpCollateral, uint256 rlusdBorrowed) external view returns (uint256) {
        uint256 collateralValue = collateralValueInLoanToken(fxrpCollateral);
        if (collateralValue == 0) return rlusdBorrowed == 0 ? 0 : type(uint256).max;
        return (rlusdBorrowed * BPS) / collateralValue;
    }

    /* ══════════════════════════════ NAV MARK ══════════════════════════════ */

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "FXRP / USD (RedStone XRP, peg-guarded NAV mark)";
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    /// @notice Conservative FXRP/USD for Fusion NAV. Never exceeds the XRP mark.
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 rid, int256 xrpUsd, uint256 started, uint256 updated, uint80 air) = XRP_USD.latestRoundData();

        if (xrpUsd <= 0) revert InvalidPrice(xrpUsd);
        if (block.timestamp - updated > MAX_STALENESS) revert StalePrice(updated, MAX_STALENESS);

        uint256 xrpMark = uint256(xrpUsd);
        uint256 floorPrice = (xrpMark * (BPS - MAX_DISCOUNT_BPS)) / BPS;

        uint256 market = _marketFxrpUsd();
        uint256 price = market < xrpMark ? market : xrpMark;
        if (price < floorPrice) price = floorPrice;

        return (rid, int256(price), started, updated, air);
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert NoHistoricalRounds();
    }

    /* ══════════════════════════════ peg views ═════════════════════════════ */

    /// @dev Returns type(uint256).max on any failure so min() degrades to the XRP mark
    ///      rather than to zero.
    function _marketFxrpUsd() internal view returns (uint256) {
        (bool ok, int24 tick) = _consult();
        if (!ok) return type(uint256).max;

        // 1 FXRP (1e6) quoted in RLUSD (18dp)
        uint256 fxrpInRlusd = OracleLibrary.getQuoteAtTick(tick, 1e6, FXRP, RLUSD);

        (, int256 rlusdUsd,, uint256 updated,) = RLUSD_USD.latestRoundData();
        if (rlusdUsd <= 0 || block.timestamp - updated > MAX_STALENESS) return type(uint256).max;

        // (18dp RLUSD) * (8dp USD) / 1e18 → 8dp USD
        return (fxrpInRlusd * uint256(rlusdUsd)) / 1e18;
    }

    function _consult() internal view returns (bool ok, int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        try POOL.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            tick = int24(delta / int56(uint56(TWAP_WINDOW)));
            if (delta < 0 && (delta % int56(uint56(TWAP_WINDOW)) != 0)) tick--;
            return (true, tick);
        } catch {
            return (false, 0);
        }
    }

    /// @notice FXRP discount to XRP in bps. Zero at or above parity.
    function pegDiscountBps() public view returns (uint256) {
        (, int256 xrpUsd,,,) = XRP_USD.latestRoundData();
        if (xrpUsd <= 0) return 0;

        uint256 market = _marketFxrpUsd();
        if (market == type(uint256).max || market >= uint256(xrpUsd)) return 0;

        return ((uint256(xrpUsd) - market) * BPS) / uint256(xrpUsd);
    }

    /// @notice False when FXRP has depegged past tolerance.
    /// @dev The pre-hook must block leverage-increasing actions on false EVEN THOUGH
    ///      Morpho will not liquidate — adding leverage into depegging collateral is
    ///      wrong regardless of whether the lender has noticed.
    function isPegHealthy() external view returns (bool) {
        return pegDiscountBps() <= PEG_TOLERANCE_BPS;
    }

    /// @notice True when the NAV mark has stopped tracking market and pinned to the
    ///         floor. Governance pauses; the oracle does not liquidate you.
    function isFlooredOut() external view returns (bool) {
        return pegDiscountBps() > MAX_DISCOUNT_BPS;
    }

    /// @notice Divergence between the two marks, bps. Non-zero means a depeg is being
    ///         written down in NAV while Morpho still marks collateral at par.
    ///         This is the number Hypernative should alert on.
    function markDivergenceBps() external view returns (uint256) {
        (, int256 xrpUsd,,,) = XRP_USD.latestRoundData();
        if (xrpUsd <= 0) return 0;
        (, int256 nav,,,) = latestRoundData();
        if (nav >= xrpUsd) return 0;
        return ((uint256(xrpUsd) - uint256(nav)) * BPS) / uint256(xrpUsd);
    }
}
