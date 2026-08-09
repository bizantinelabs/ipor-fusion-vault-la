// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMorpho, MarketParams, Id, Position, Market} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-org/morpho-blue/src/interfaces/IOracle.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MathLib} from "@morpho-org/morpho-blue/src/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/morpho-blue/src/libraries/ConstantsLib.sol";

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

interface IPegView {
    function isPegHealthy() external view returns (bool);
}

/// @title MorphoLtvGuardedFuse
/// @notice DRAFT — UNAUDITED. Do not deploy or whitelist without independent review.
///         This contract is the sole on-chain enforcement of the vault's leverage limit. It is
///         the single highest-value audit target in this package.
///
/// WHY THIS EXISTS (and why it is not a pre-hook)
/// ---------------------------------------------
/// bizFXRP-ETH_FULL_SPEC.md §9 specifies a "custom LTV pre-hook" that "simulates the post-action
/// position using Morpho's own oracle arithmetic and reverts every action that would exceed 40%
/// LTV". That cannot be built as an IPreHook. Verified against the real repo:
///
///     PreHooksHandler._runPreHook(bytes4 selector_) calls
///         implementation.functionDelegateCall(abi.encodeWithSelector(IPreHook.run.selector, selector_))
///
/// A pre-hook receives ONLY the top-level function selector — never the pending FuseAction[]
/// calldata — and runs once, before any batched action executes. It therefore cannot know what a
/// given execute() call is about to do, and cannot simulate its result. See FINDINGS.md §6.
///
/// The enforcement has to live where the action data actually is: in the fuse. That is this
/// contract.
///
/// DESIGN: CHECK REAL POST-STATE, DO NOT SIMULATE
/// ----------------------------------------------
/// Rather than predicting the resulting position, this fuse performs the operation and then reads
/// the REAL resulting position back out of Morpho, reverting the whole transaction if the limit is
/// breached. Because the check and the action share one transaction, a revert cleanly undoes the
/// borrow/withdrawal. This is strictly stronger than simulation: there is no arithmetic to keep in
/// sync with Morpho, so there is no replication risk — the failure mode where a simulator drifts
/// out of agreement with the protocol it models simply cannot occur here.
///
/// The LTV math below is copied from Morpho's own `_isHealthy` (Morpho.sol), including its rounding
/// directions: borrowed is rounded UP (`toAssetsUp`) and collateral value is rounded DOWN
/// (`mulDivDown`). Both round against the borrower, so the computed LTV is conservative (high).
///
/// PRECONDITION on accrual: every Morpho entrypoint used here (`borrow`, `withdrawCollateral`)
/// calls `_accrueInterest` internally before returning, so reading `market()`/`position()`
/// immediately afterwards yields exact, freshly-accrued values. Do not reuse `_assertLtvWithinLimit`
/// in a context where no accrual has just occurred without switching to
/// MorphoBalancesLib.expectedBorrowAssets.
///
/// BOTH leverage-increasing paths are guarded — this is easy to get wrong:
///     1. borrowing more                  -> `borrow()`
///     2. WITHDRAWING COLLATERAL          -> `withdrawCollateral()`
/// Guarding only the borrow leg would leave collateral withdrawal as an unguarded route to an
/// arbitrarily high LTV. Repay and supplyCollateral are intentionally ungated: both strictly
/// reduce LTV, and gating them could block an emergency delever.
///
/// LTV mark: read directly from `marketParams.oracle` — Morpho's own oracle for the market. Per
/// spec §5.2, "LTV calculations must never use the NAV mark." The conservative NAV mark from
/// FXRPPriceFeedEthereum is used ONLY for the peg check, never for the LTV denominator.
contract MorphoLtvGuardedFuse is IFuseCommon {
    using SharesMathLib for uint256;
    using MathLib for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IMorpho public immutable MORPHO;

    /// @notice Hard maximum LTV in basis points. Spec §9: 40% hard max (LLTV is 77%).
    uint256 public immutable HARD_MAX_LTV_BPS;

    /// @notice FXRPPriceFeedEthereum, used ONLY for isPegHealthy(). Never for LTV.
    /// @dev Required non-zero at construction: deploy the price feed first. Making this optional
    ///      would create a permanent silent-bypass footgun, since it is immutable.
    IPegView public immutable PEG_VIEW;

    uint256 private constant _BPS = 10_000;

    error UnsupportedMorphoMarket(bytes32 morphoMarketId);
    error LtvExceedsHardMax(uint256 ltvBps, uint256 hardMaxBps);
    error PegUnhealthyLeverageBlocked();
    error ZeroAddress();
    error InvalidHardMaxLtv(uint256 hardMaxBps);

    event LtvGuardedBorrow(bytes32 morphoMarketId, uint256 assetsBorrowed, uint256 resultingLtvBps);
    event LtvGuardedCollateralWithdraw(bytes32 morphoMarketId, uint256 collateralWithdrawn, uint256 resultingLtvBps);

    constructor(uint256 marketId_, address morpho_, uint256 hardMaxLtvBps_, address pegView_) {
        if (morpho_ == address(0) || pegView_ == address(0)) revert ZeroAddress();
        // A hard max at or above the market LLTV would be no limit at all (the position would be
        // liquidatable before the guard ever fired). Spec value is 4000 against a 7700 LLTV.
        if (hardMaxLtvBps_ == 0 || hardMaxLtvBps_ >= _BPS) revert InvalidHardMaxLtv(hardMaxLtvBps_);

        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
        HARD_MAX_LTV_BPS = hardMaxLtvBps_;
        PEG_VIEW = IPegView(pegView_);
    }

    /* ─────────────────────────── leverage-INCREASING (guarded) ─────────────────────────── */

    /// @notice Borrow from Morpho, then revert if the resulting LTV exceeds the hard max.
    function borrow(bytes32 morphoMarketId_, uint256 amountToBorrow_, uint256 sharesToBorrow_) external {
        if (amountToBorrow_ == 0 && sharesToBorrow_ == 0) return;
        MarketParams memory mp = _requireGrantedMarket(morphoMarketId_);

        // Spec §9: block leverage-increasing actions when the peg is unhealthy, even though Morpho
        // itself will not liquidate on an FXRP depeg (its oracle prices native XRP).
        if (!PEG_VIEW.isPegHealthy()) revert PegUnhealthyLeverageBlocked();

        (uint256 assetsBorrowed, ) = MORPHO.borrow(mp, amountToBorrow_, sharesToBorrow_, address(this), address(this));

        uint256 ltvBps = _assertLtvWithinLimit(mp, morphoMarketId_);
        emit LtvGuardedBorrow(morphoMarketId_, assetsBorrowed, ltvBps);
    }

    /// @notice Withdraw collateral, then revert if the resulting LTV exceeds the hard max.
    /// @dev This path is as dangerous as borrowing — withdrawing collateral raises LTV just as
    ///      surely as taking on debt. It is guarded identically and deliberately.
    ///      Note it is NOT peg-gated: a delever sequence (repay -> withdraw collateral) must remain
    ///      possible while the peg is unhealthy, which is precisely when it is most needed. The LTV
    ///      check still applies, so this cannot be used to lever up.
    function withdrawCollateral(bytes32 morphoMarketId_, uint256 collateralAmount_) external {
        if (collateralAmount_ == 0) return;
        MarketParams memory mp = _requireGrantedMarket(morphoMarketId_);

        MORPHO.withdrawCollateral(mp, collateralAmount_, address(this), address(this));

        uint256 ltvBps = _assertLtvWithinLimit(mp, morphoMarketId_);
        emit LtvGuardedCollateralWithdraw(morphoMarketId_, collateralAmount_, ltvBps);
    }

    /* ─────────────────────────── leverage-REDUCING (ungated) ─────────────────────────── */

    /// @notice Repay debt. Ungated: strictly reduces LTV, and must never be blocked.
    function repay(bytes32 morphoMarketId_, uint256 amountToRepay_, uint256 sharesToRepay_) external {
        if (amountToRepay_ == 0 && sharesToRepay_ == 0) return;
        MarketParams memory mp = _requireGrantedMarket(morphoMarketId_);
        MORPHO.repay(mp, amountToRepay_, sharesToRepay_, address(this), bytes(""));
    }

    /// @notice Supply collateral. Ungated: strictly reduces LTV.
    function supplyCollateral(bytes32 morphoMarketId_, uint256 collateralAmount_) external {
        if (collateralAmount_ == 0) return;
        MarketParams memory mp = _requireGrantedMarket(morphoMarketId_);
        MORPHO.supplyCollateral(mp, collateralAmount_, address(this), bytes(""));
    }

    /* ─────────────────────────────────── views ─────────────────────────────────── */

    /// @notice Current LTV of this vault's position, in bps, computed exactly as Morpho would.
    /// @dev View-only convenience for monitoring (Hypernative thresholds at 37%/40% per spec §16).
    ///      Does NOT accrue interest, so it can read very slightly low between accruals; the
    ///      enforcement path in `_assertLtvWithinLimit` always runs immediately post-accrual.
    function currentLtvBps(bytes32 morphoMarketId_) external view returns (uint256) {
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(morphoMarketId_));
        return _computeLtvBps(mp, morphoMarketId_);
    }

    /* ────────────────────────────────── internals ────────────────────────────────── */

    function _requireGrantedMarket(bytes32 morphoMarketId_) private view returns (MarketParams memory mp) {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, morphoMarketId_)) {
            revert UnsupportedMorphoMarket(morphoMarketId_);
        }
        mp = MORPHO.idToMarketParams(Id.wrap(morphoMarketId_));
    }

    function _assertLtvWithinLimit(MarketParams memory mp_, bytes32 morphoMarketId_) private view returns (uint256 ltvBps) {
        ltvBps = _computeLtvBps(mp_, morphoMarketId_);
        if (ltvBps > HARD_MAX_LTV_BPS) revert LtvExceedsHardMax(ltvBps, HARD_MAX_LTV_BPS);
    }

    /// @dev Mirrors Morpho.sol `_isHealthy` exactly, including rounding direction:
    ///        borrowed        = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares)  [rounds UP]
    ///        collateralValue = collateral.mulDivDown(price, ORACLE_PRICE_SCALE)               [rounds DOWN]
    ///      Both round against the borrower, so the resulting LTV is conservative (biased high).
    function _computeLtvBps(MarketParams memory mp_, bytes32 morphoMarketId_) private view returns (uint256) {
        Id id = Id.wrap(morphoMarketId_);
        Position memory pos = MORPHO.position(id, address(this));

        if (pos.borrowShares == 0) return 0;

        Market memory mkt = MORPHO.market(id);
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);

        // Morpho's own oracle for this market. Never the NAV mark (spec §5.2).
        uint256 collateralPrice = IOracle(mp_.oracle).price();
        uint256 collateralValue = uint256(pos.collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);

        // Debt with zero collateral value is unbounded LTV — always breach.
        if (collateralValue == 0) return type(uint256).max;

        return (borrowed * _BPS) / collateralValue;
    }
}
