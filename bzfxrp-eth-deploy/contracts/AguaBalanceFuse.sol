// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketBalanceFuse} from "contracts/fuses/IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {AguaFuseStorageLib} from "./AguaFuseStorageLib.sol";

/// @notice DRAFT — UNAUDITED. Do not deploy or whitelist without independent review.
///
/// Structured directly on the real Erc4626BalanceFuse.sol pattern from IPOR-Labs/ipor-fusion
/// (balanceOf() -> USD, 18dp, via PlasmaVaultLib.getPriceOracleMiddleware() +
/// IPriceOracleMiddleware.getAssetPrice(asset) + IporMath.convertToWad) rather than invented from
/// scratch. The Agua-specific part is the valuation rule from the deployment package (§7):
///
///   "Marking a levered NAV off a declared rate reports profit that may not exist. Hold Agua at
///    cost. Recognise gain only on completeRedemption. The balance fuse returns
///    min(costBasis, declaredValue)."
///
/// and C3: while a redemption request is pending, value the pending portion using the
/// cumulativeRateFactor SNAPSHOTTED at request time (via AguaFuseStorageLib), not the live factor,
/// so NAV does not silently drift upward during the 5-day queue.
///
/// UNVERIFIED: the exact selector/return type of Agua's `cumulativeRateFactor()` and whether Agua
/// itself exposes a queryable `yieldFactorAtRequest` per-request (preferable to this contract's own
/// mirrored snapshot if so) — confirm against Agua's real source before deployment. This contract's
/// `cumulativeRateFactor()` call was verified live to return a sane RAY-scaled value
/// (~1.0141e27) against 0xa98b4a70e17e55045cde4972b95bc2e8cec22a0f on 2026-08-09, but the exact
/// units/rounding contract have not been independently confirmed beyond that single read.
contract AguaBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;
    address public immutable AGUA;
    address public immutable ASSET; // USDC

    uint256 private constant _RAY = 1e27;

    constructor(uint256 marketId_, address agua_, address asset_) {
        MARKET_ID = marketId_;
        AGUA = agua_;
        ASSET = asset_;
    }

    function balanceOf() external view override returns (uint256) {
        AguaFuseStorageLib.AguaState storage state = AguaFuseStorageLib.getState();

        uint256 shares = IERC20(AGUA).balanceOf(address(this));
        if (shares == 0 && state.costBasisUsdc == 0) {
            return 0;
        }

        // Declared value per §4/§7's stated formula:
        //   assets = shares * cumulativeRateFactor / RAY / decimalOffset(1e12)
        // The 1e12 offset converts Agua's 18dp shares to USDC's 6dp before this fuse re-expands
        // to 18dp USD below — i.e. it is Agua-share-decimals-to-USDC-decimals normalization, not
        // a NAV discount. UNVERIFIED against Agua's real decimals wiring; confirm before use.
        uint256 rateFactor = state.requestPending ? state.rateFactorAtRequest : _liveCumulativeRateFactor();
        uint256 declaredValueUsdc = (shares * rateFactor) / _RAY / 1e12;

        // Hold at cost: never report more than what was actually deposited and not yet recognized.
        uint256 costBasisUsdc = state.costBasisUsdc;
        uint256 valueUsdc = declaredValueUsdc < costBasisUsdc ? declaredValueUsdc : costBasisUsdc;

        if (valueUsdc == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(ASSET);
        // ASSET (USDC) decimals hardcoded to 6 here per the deployment package; if this fuse is
        // ever reused for a different asset, read decimals() instead of assuming.
        return IporMath.convertToWad(valueUsdc * price, 6 + priceDecimals);
    }

    /// @dev UNVERIFIED SIGNATURE — confirm against real Agua source before use.
    function _liveCumulativeRateFactor() private view returns (uint256) {
        (bool ok, bytes memory ret) = AGUA.staticcall(abi.encodeWithSignature("cumulativeRateFactor()"));
        require(ok, "AguaBalanceFuse: cumulativeRateFactor() call failed");
        return abi.decode(ret, (uint256));
    }
}
