// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

// solhint-disable no-inline-assembly

/**
 * @title TransientReentrancyGuard
 * @notice Reentrancy guard kept in transient storage (EIP-1153), for DogeOS contracts.
 * @dev Declares no storage, so it can be added to an upgradeable contract that keeps
 * OpenZeppelin's ReentrancyGuardUpgradeable for its storage layout: the persistent `_status`
 * slot and gap stay in place, unused. The OZ guard costs a cold storage read plus two writes
 * per guarded call; this one costs a transient read and two transient writes.
 *
 * Only for chains where TSTORE/TLOAD are enabled: DogeOS enables them from Scroll's Curie
 * fork, and every DogeOS network is at Feynman or later. The flag is cleared on exit, so it
 * does not rely on the end-of-transaction clearing. Guarded functions must not be reachable
 * through STATICCALL (TSTORE reverts there); they are state-changing entry points.
 */
abstract contract TransientReentrancyGuard {
    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1))
    ///      & ~bytes32(uint256(0xff)), the slot OpenZeppelin 5.1's ReentrancyGuardTransient uses.
    bytes32 private constant REENTRANCY_GUARD_SLOT = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    /// @dev Prevents a function from being re-entered while it (or another guarded function of
    ///      the same contract) is executing. Reverts with the same message as OpenZeppelin's guard.
    modifier nonReentrantTransient() {
        bool entered;
        assembly {
            entered := tload(REENTRANCY_GUARD_SLOT)
        }
        require(!entered, "ReentrancyGuard: reentrant call");
        assembly {
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly {
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }
}
