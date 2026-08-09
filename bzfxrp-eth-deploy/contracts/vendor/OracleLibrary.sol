// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {TickMath} from "./TickMath.sol";
import {FullMath} from "./FullMath.sol";

/// @title OracleLibrary (0.8.30 port, getQuoteAtTick only)
// DRAFT -- provenance note (read before using):
//   The canonical Uniswap v3-periphery OracleLibrary.sol (npm package @uniswap/v3-periphery) is
//   pragma solidity >=0.5.0 <0.8.0 and cannot be imported into a pragma solidity 0.8.30 project
//   (this repo's compiler pin). FXRPPriceFeedEthereum.sol imports this file from
//   ./vendor/OracleLibrary.sol but that file was not included in the deployment package -- this
//   is the missing piece, reconstructed here.
//
//   This is NOT an original derivation. It is:
//     1. TickMath.sol and FullMath.sol copied VERBATIM from IPOR-Labs/ipor-fusion
//        (contracts/fuses/uniswap/ext/{TickMath,FullMath}.sol, pragma >=0.8.30) -- the same
//        libraries IPOR already uses in production for its Uniswap V4 / Ramses V2 fuses.
//     2. getQuoteAtTick below reproduces, line for line, the real Uniswap v3-periphery
//        OracleLibrary.getQuoteAtTick (GPL-2.0-or-later), only pointed at the two files above
//        instead of the 0.7.6-only originals.
//   No arithmetic here was authored by inspection of the spec's prose -- every line traces to a
//   real, already-deployed source. That said, this exact composition (0.8-ported TickMath/FullMath
//   driving getQuoteAtTick) has not itself been used in a live IPOR Fusion price feed to my
//   knowledge -- treat it as unaudited until reviewed, same as the rest of this package.
library OracleLibrary {
    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
    /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
    /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
