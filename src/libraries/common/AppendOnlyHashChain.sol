// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title AppendOnlyHashChain
/// @notice Commits an ordered message sequence as `root = keccak256(root || messageHash)`.
abstract contract AppendOnlyHashChain {
    /// @notice Full-width Keccak commitment to the ordered message sequence.
    /// @dev Zero for a queue created at genesis. On a queue upgraded by code replacement it
    /// continues from the authenticated checkpoint root (the chain's seed).
    bytes32 public messageRoot;

    /// @notice The next unused message index.
    uint256 public nextMessageIndex;

    /// @dev The former AppendOnlyMerkleTree `zeroHashes[40]` (slots 2..41) and `branches[40]`
    /// (slots 42..81), kept so that `owner` and `messenger` stay at slots 82/83 (2 + 40 + 40 = 82).
    /// On a chain upgraded by code replacement these slots still hold the old tree values and are
    /// NOT zero: never reuse them for new state.
    uint256[80] private __legacyTreeSlots;

    /// @dev Appends `_messageHash` and returns `(index, newRoot)`. The count is capped at
    /// `type(uint64).max` because the bridge protocol carries it as a u64.
    function _appendMessageHash(bytes32 _messageHash) internal returns (uint256, bytes32) {
        uint256 _index = nextMessageIndex;
        require(_index < type(uint64).max, "message index overflow");
        bytes32 _hash = keccak256(abi.encodePacked(messageRoot, _messageHash));
        messageRoot = _hash;
        nextMessageIndex = _index + 1;
        return (_index, _hash);
    }
}
