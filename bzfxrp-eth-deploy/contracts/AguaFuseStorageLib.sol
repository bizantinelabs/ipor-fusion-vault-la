// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice DRAFT — UNAUDITED. Shared storage for AguaSupplyFuse and AguaBalanceFuse.
/// @dev Both fuses are separate contract addresses but are delegatecalled from the same
/// PlasmaVault, so they must agree on a storage slot to share cost-basis / pending-request
/// state. Follows the same "dedicated storage slot via keccak256" pattern used throughout
/// ipor-fusion (see e.g. PlasmaVaultStorageLib) rather than plain mapping storage colliding
/// with other fuses' layout.
library AguaFuseStorageLib {
    // keccak256("bzfxrp-eth.agua.fuse.storage.v1") — placeholder derivation; regenerate and
    // pin explicitly before any real deployment, and verify no collision with existing
    // ipor-fusion storage slots used elsewhere in PlasmaVault's storage space.
    bytes32 private constant _STORAGE_SLOT = 0x9f5f2b6c9f9a1c9a6a8b0e5d8c9e0e6d9f1c9a6a8b0e5d8c9e0e6d9f1c9a6a8b;

    struct AguaState {
        /// @dev Cumulative USDC deposited into Agua, net of amounts already recognized via
        /// completeRedemption/exitEarly. This is the "cost basis" the deployment package (§7)
        /// requires the balance fuse to cap declared value at.
        uint256 costBasisUsdc;
        /// @dev True while an exit request is pending (mirrors AguaSupplyFuse's own pending-request
        /// flag; duplicated here so the balance fuse can read it without depending on the supply
        /// fuse's contract, since both are delegatecalled independently).
        bool requestPending;
        /// @dev Agua's cumulativeRateFactor (RAY-scaled) captured at the moment exitRequest was
        /// called. Per §7 C3: "yieldFactorAtRequest is snapshotted... the balance fuse must use
        /// the snapshot, not live factor, once a request is open — otherwise NAV overstates
        /// during the queue." CONFIRM this is the same snapshot semantics Agua itself uses
        /// internally (the deployment package refers to Agua's own `yieldFactorAtRequest`, which
        /// may or may not be readable directly from Agua rather than needing to be re-captured
        /// here — if Agua exposes it, prefer reading Agua's value directly over trusting this
        /// mirror).
        uint256 rateFactorAtRequest;
        /// @dev Shares associated with the pending request, needed to value the frozen portion.
        uint256 pendingRequestShares;
    }

    function getState() internal pure returns (AguaState storage state) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
