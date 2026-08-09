// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {AguaFuseStorageLib} from "./AguaFuseStorageLib.sol";

/// @notice DRAFT — UNAUDITED. Do not deploy or whitelist without independent review.
///
/// Provenance / verification status (read before relying on this):
///   - View functions below were cross-checked live on Ethereum mainnet against
///     0xa98b4a70e17e55045cde4972b95bc2e8cec22a0f on 2026-08-09:
///       earlyRedemptionFee() == 500        (matches "5% fee" in the deployment package)
///       lockupPeriod()       == 432000     (matches "5-day wait" exactly)
///       maxWithdraw/maxRedeem == 0          (confirms non-4626-compliant exit, as documented)
///     This strongly corroborates the deployment package's description of Agua's interface.
///   - The STATE-CHANGING function signatures below (deposit/requestRedemption/
///     completeRedemption/redeemEarly/cancelRedemption) were NOT independently verified —
///     Agua is not verified on Sourcify and no ABI could be fetched. They are taken directly
///     from the deployment package's prose. CONFIRM the exact selector, parameter order, and
///     return type of each against Agua's real source (or their team) before this fuse is
///     compiled against a live target — a wrong selector reverts safely, but a right selector
///     with wrong parameter order does not, and would not be caught by testing alone.
///
/// Encodes constraints C1/C2/C4 from the deployment package (§7):
///   C1 — one active request per address (the vault is one address; exitRequest must not
///        allow a second concurrent request).
///   C2 — minAssetsOut must be enforced non-zero here, because Agua's own check does not fire
///        at zero.
///   C4 — unlockTime is snapshotted by Agua at request time; nothing to enforce here, this
///        fuse just surfaces it for the Alpha/monitoring to read.
///   C3 (yield freezes at request) is a BALANCE accounting concern — see AguaBalanceFuse.sol.
contract AguaSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @dev Market id is a constructor param, matching the real ZeroBalanceFuse/fuse pattern in
    /// ipor-fusion (MARKET_ID is set via constructor, not hardcoded). What value to use is a real
    /// open question: on-chain, live vaults use IporFusionMarkets.sol allocated ids (0-37+) for
    /// standard protocols; Agua has no allocated id there. Confirm with IPOR whether this needs a
    /// newly allocated id or can use a vault-local sentinel akin to the observed
    /// MARKET_ID()==type(uint256).max utility-fuse pattern (0x79e8B115...ab4, confirmed present on
    /// three live vaults including this one — likely a factory-installed BurnRequestFeeFuse, not a
    /// precedent for custom strategy fuses). Do not assume type(uint256).max is correct by default.
    uint256 public immutable MARKET_ID;

    address public immutable AGUA;
    address public immutable ASSET; // USDC, per the deployment package (Agua Global Carry decimals()==18, asset()==USDC)

    error RequestAlreadyPending();
    error NoPendingRequest();
    error ZeroMinAssetsOut();
    error AguaNotSupportedMarket();

    event AguaEnter(uint256 assets, uint256 sharesReceived);
    event AguaExitRequested(uint256 shares, uint256 rateFactorSnapshot);
    event AguaExitCompleted(uint256 assetsReceived, uint256 costBasisReleased);
    event AguaExitEarly(uint256 shares, uint256 minAssetsOut, uint256 assetsReceived, uint256 costBasisReleased);
    event AguaExitCancelled();

    constructor(uint256 marketId_, address agua_, address asset_) {
        MARKET_ID = marketId_;
        AGUA = agua_;
        ASSET = asset_;
    }

    /// @param assets_ USDC amount to deposit into Agua
    function enter(uint256 assets_) external {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, PlasmaVaultConfigLib.addressToBytes32(AGUA))) {
            revert AguaNotSupportedMarket();
        }
        IERC20(ASSET).forceApprove(AGUA, assets_);
        // UNVERIFIED SIGNATURE — confirm against real Agua source before use.
        // Per deployment package: agua.deposit(assets, address(this))
        uint256 sharesBefore = IERC20(AGUA).balanceOf(address(this));
        (bool ok, bytes memory ret) = AGUA.call(
            abi.encodeWithSignature("deposit(uint256,address)", assets_, address(this))
        );
        require(ok, string(ret));
        uint256 sharesReceived = IERC20(AGUA).balanceOf(address(this)) - sharesBefore;

        // §7: "Hold Agua at cost." Cost basis grows by exactly what was deposited, never by a
        // declared rate. Deliberately ignores sharesReceived for valuation purposes.
        AguaFuseStorageLib.getState().costBasisUsdc += assets_;

        emit AguaEnter(assets_, sharesReceived);
    }

    /// @param shares_ Agua shares to request redemption for
    /// @param currentRateFactor_ Agua's live cumulativeRateFactor at call time (RAY-scaled),
    ///        passed in by the caller rather than read here — prefer reading it directly from
    ///        Agua inside this function once its real getter signature is confirmed; this
    ///        parameter is a placeholder for that.
    function exitRequest(uint256 shares_, uint256 currentRateFactor_) external {
        AguaFuseStorageLib.AguaState storage state = AguaFuseStorageLib.getState();
        if (state.requestPending) revert RequestAlreadyPending(); // C1
        // UNVERIFIED SIGNATURE — confirm against real Agua source before use.
        // Per deployment package: agua.requestRedemption(shares)
        (bool ok, bytes memory ret) = AGUA.call(abi.encodeWithSignature("requestRedemption(uint256)", shares_));
        require(ok, string(ret));
        state.requestPending = true;
        state.pendingRequestShares = shares_;
        state.rateFactorAtRequest = currentRateFactor_; // C3 snapshot
        emit AguaExitRequested(shares_, currentRateFactor_);
    }

    /// @param costBasisForRequest_ The portion of costBasisUsdc attributable to the shares being
    ///        redeemed. The caller (Alpha policy / a wrapping contract) must compute this
    ///        proportionally — e.g. costBasisUsdc * pendingRequestShares / totalSharesAtRequest —
    ///        since this fuse does not itself track a full lot-accounting ledger. Passing the
    ///        wrong value here directly misstates NAV; this is a real gap in this draft, not a
    ///        cosmetic one.
    function exitComplete(uint256 costBasisForRequest_) external {
        AguaFuseStorageLib.AguaState storage state = AguaFuseStorageLib.getState();
        if (!state.requestPending) revert NoPendingRequest();
        // UNVERIFIED SIGNATURE — confirm against real Agua source before use.
        // Per deployment package: agua.completeRedemption(address(this))
        uint256 assetsBefore = IERC20(ASSET).balanceOf(address(this));
        (bool ok, bytes memory ret) = AGUA.call(
            abi.encodeWithSignature("completeRedemption(address)", address(this))
        );
        require(ok, string(ret));
        uint256 assetsReceived = IERC20(ASSET).balanceOf(address(this)) - assetsBefore;

        state.costBasisUsdc -= costBasisForRequest_;
        delete state.requestPending;
        delete state.pendingRequestShares;
        delete state.rateFactorAtRequest;

        emit AguaExitCompleted(assetsReceived, costBasisForRequest_);
    }

    /// @param shares_ Agua shares to redeem early
    /// @param minAssetsOut_ MUST be non-zero — Agua's own `assets < minAssetsOut` check does not
    ///        fire at zero (C2). Deployment package suggests a floor of 94% of
    ///        shares * cumulativeRateFactor (5% fee + 100bps tolerance) — compute that off-chain
    ///        or in a wrapping Alpha-policy contract and pass it in; this fuse only enforces
    ///        non-zero, it does not compute the floor itself.
    /// @param costBasisForRequest_ See exitComplete — same caveat applies.
    function exitEarly(uint256 shares_, uint256 minAssetsOut_, uint256 costBasisForRequest_) external {
        if (minAssetsOut_ == 0) revert ZeroMinAssetsOut(); // C2
        AguaFuseStorageLib.AguaState storage state = AguaFuseStorageLib.getState();
        // UNVERIFIED SIGNATURE — confirm against real Agua source before use.
        // Per deployment package: agua.redeemEarly(shares, address(this), minAssetsOut)
        uint256 assetsBefore = IERC20(ASSET).balanceOf(address(this));
        (bool ok, bytes memory ret) = AGUA.call(
            abi.encodeWithSignature("redeemEarly(uint256,address,uint256)", shares_, address(this), minAssetsOut_)
        );
        require(ok, string(ret));
        uint256 assetsReceived = IERC20(ASSET).balanceOf(address(this)) - assetsBefore;

        state.costBasisUsdc -= costBasisForRequest_;
        delete state.requestPending;
        delete state.pendingRequestShares;
        delete state.rateFactorAtRequest;

        emit AguaExitEarly(shares_, minAssetsOut_, assetsReceived, costBasisForRequest_);
    }

    function exitCancel() external {
        AguaFuseStorageLib.AguaState storage state = AguaFuseStorageLib.getState();
        if (!state.requestPending) revert NoPendingRequest();
        // UNVERIFIED SIGNATURE — confirm against real Agua source before use.
        // Per deployment package: agua.cancelRedemption()
        (bool ok, bytes memory ret) = AGUA.call(abi.encodeWithSignature("cancelRedemption()"));
        require(ok, string(ret));
        // Cost basis is untouched — cancelling a request does not release any assets.
        delete state.requestPending;
        delete state.pendingRequestShares;
        delete state.rateFactorAtRequest;
        emit AguaExitCancelled();
    }

    function hasPendingRequest() external view returns (bool) {
        return AguaFuseStorageLib.getState().requestPending;
    }
}
