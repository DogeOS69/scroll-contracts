// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

abstract contract AppendOnlyMerkleTree {
    /// @dev The maximum height of the withdraw merkle tree.
    uint256 private constant MAX_TREE_HEIGHT = 40;

    /// @notice The merkle root of the current merkle tree.
    bytes32 public messageRoot;

    /// @notice The next unused message index.
    uint256 public nextMessageIndex;

    /// @notice The list of zero hash in each height.
    bytes32[MAX_TREE_HEIGHT] private zeroHashes;

    /// @notice The list of minimum merkle proofs needed to compute next root.
    /// @dev Only first `n` elements are used, where `n` is the minimum value that `2^{n-1} >= currentMaxNonce + 1`.
    /// It means we only use `currentMaxNonce + 1` leaf nodes to construct the merkle tree.
    /// Only the live frontier is meaningful: `branches[h]` for each set bit `h` of
    /// `nextMessageIndex` (the completed left subtrees). Other entries may be stale.
    bytes32[MAX_TREE_HEIGHT] public branches;

    function _initializeMerkleTree() internal {
        // Compute hashes in empty sparse Merkle tree
        for (uint256 height = 0; height + 1 < MAX_TREE_HEIGHT; height++) {
            zeroHashes[height + 1] = _efficientHash(zeroHashes[height], zeroHashes[height]);
        }
    }

    /// @dev Appends `_messageHash` as leaf `nextMessageIndex` and updates `messageRoot`.
    ///
    /// Produces exactly the same `messageRoot` / `nextMessageIndex` sequence as the original
    /// Scroll implementation, with two gas optimizations:
    ///
    /// 1. Only ONE `branches` slot is written per append: the one at height `t`, the number
    ///    of trailing one bits of the leaf index. That is the only write a later append can
    ///    read: `branches[h]` is read by an append whose index has bit `h` set, and the last
    ///    append before it with bit `h` clear is the one whose low `h` bits are all ones
    ///    (so `t == h`), at which point the level-`h` subtree it completes is final. The
    ///    original also wrote partial (not-yet-complete) left subtrees at every clear bit and
    ///    the root at `branches[height]`; no later append reads those values before they are
    ///    overwritten by the completing append, so skipping them does not change any root.
    ///    Consequently `branches(h)` for heights that are not part of the live frontier may
    ///    hold stale values, and `branches(height)` no longer mirrors `messageRoot`.
    /// 2. Zero-subtree hashes are derived on the fly (`z_{h+1} = keccak(z_h, z_h)`, one
    ///    in-memory keccak per level) instead of one cold SLOAD of `zeroHashes[h]` per clear
    ///    bit. `zeroHashes` is still initialized so the storage layout and contents are unchanged.
    ///
    /// The original's "call before initialization" check read `zeroHashes[1]`; callers must
    /// gate appends on initialization themselves (L2MessageQueue does: `messenger` is only
    /// set by `initialize`, which also initializes the tree, and `appendMessage` requires
    /// `msg.sender == messenger`).
    function _appendMessageHash(bytes32 _messageHash) internal returns (uint256, bytes32) {
        uint256 _currentMessageIndex = nextMessageIndex;
        // The original indexed `branches[40]` (out of bounds) for the leaf at index 2^39;
        // keep that capacity limit explicitly since fewer slots are touched now.
        require(_currentMessageIndex < (1 << (MAX_TREE_HEIGHT - 1)), "merkle tree is full");

        uint256 _index = _currentMessageIndex;
        bytes32 _hash = _messageHash;
        bytes32 _zero; // zeroHashes[_height]
        uint256 _height = 0;
        bool _stored = false;

        while (_index != 0) {
            if (_index & 1 == 0) {
                // left child; only the first one (height == trailing ones) is ever read again.
                if (!_stored) {
                    branches[_height] = _hash;
                    _stored = true;
                }
                _hash = _efficientHash(_hash, _zero);
            } else {
                // right child, use the completed left sibling
                _hash = _efficientHash(branches[_height], _hash);
            }
            _zero = _efficientHash(_zero, _zero);
            unchecked {
                _height += 1;
            }
            _index >>= 1;
        }

        // index == 2^k - 1: the whole tree is complete and becomes the next left sibling.
        if (!_stored) {
            branches[_height] = _hash;
        }
        messageRoot = _hash;

        unchecked {
            nextMessageIndex = _currentMessageIndex + 1;
        }

        return (_currentMessageIndex, _hash);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
