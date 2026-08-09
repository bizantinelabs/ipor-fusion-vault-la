// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "contracts/handlers/pre_hooks/IPreHook.sol";

interface IFxrpPriceFeedPegView {
    function isPegHealthy() external view returns (bool);
}

/// @notice DRAFT — UNAUDITED. Do not deploy or whitelist without independent review.
///
/// This is deliberately scoped to ONLY the peg guard from the deployment package's pre-hook table:
///   "Peg guard — Revert all leverage-increasing ops when FXRP/XRP outside 200bps"
///
/// It does NOT attempt the LTV-simulation guard ("recompute post-action; revert above 40%") — see
/// FINDINGS.md §6 for why that cannot be a generic IPreHook: `PreHooksHandler` invokes
/// `IPreHook.run(bytes4 selector_)` with only the top-level function selector, never the pending
/// FuseAction[] calldata, so a pre-hook has no way to know what a batched execute() call is about
/// to do. The peg check below needs no such visibility — it only reads external oracle state — so
/// it genuinely is implementable this way, unlike the LTV guard.
///
/// Real interface confirmed against IPOR-Labs/ipor-fusion contracts/handlers/pre_hooks/IPreHook.sol:
///   function run(bytes4 selector_) external;
/// Registered per the real PreHooksManager pattern, keyed to the execute(FuseAction[]) selector
/// (0x33f2xxxx — compute the real selector at deploy time, do not hardcode it here).
///
/// IMPORTANT — this hook cannot distinguish "leverage-increasing" from "delevering" actions,
/// because (per the above) it cannot see which actions are in the pending batch. As specced
/// ("block leverage-increasing ops"), a correctly scoped implementation would need to live inside
/// the Morpho borrow fuse wrapper alongside the LTV check (§6), where the actual action data is
/// visible. This hook, if registered on execute(), blocks ALL execute() calls (including delevers)
/// whenever the peg is unhealthy — which is MORE conservative than intended, not less: it could
/// block a legitimate emergency delever at exactly the moment the peg guard fires. Flag this
/// tradeoff to governance explicitly rather than silently accepting it; do not register this hook
/// on the general execute() selector without that sign-off.
contract PegGuardPreHook is IPreHook {
    IFxrpPriceFeedPegView public immutable PRICE_FEED;

    error PegUnhealthy();

    constructor(address priceFeed_) {
        PRICE_FEED = IFxrpPriceFeedPegView(priceFeed_);
    }

    function run(bytes4) external view override {
        if (!PRICE_FEED.isPegHealthy()) {
            revert PegUnhealthy();
        }
    }
}
