// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

abstract contract AppendOnlyHashChain {
    /// @notice Full-width Keccak commitment to the ordered message sequence.
    bytes32 public messageRoot;

    /// @notice The next unused message index.
    uint256 public nextMessageIndex;

    /// @dev Reserve the former zeroHashes/branches slots so owner and messenger stay at slots 82/83.
    uint256[80] private __reserved;

    /// @dev Fresh queues start at zero. At an upgrade, messageRoot is the authenticated checkpoint seed.
    function _appendMessageHash(bytes32 _messageHash) internal returns (uint256, bytes32) {
        uint256 _index = nextMessageIndex;
        require(_index < type(uint64).max, "message index overflow");
        bytes32 _hash = keccak256(abi.encodePacked(messageRoot, _messageHash));
        messageRoot = _hash;
        nextMessageIndex = _index + 1;
        return (_index, _hash);
    }
}
