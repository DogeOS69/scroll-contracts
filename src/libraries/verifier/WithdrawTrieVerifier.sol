// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// solhint-disable no-inline-assembly

library WithdrawTrieVerifier {
    /// @dev Verify the merkle proof given root, leaf node and proof.
    ///
    /// Vulnerability:
    ///   The initially provided message hash can be hashed with the first hash of the proof,
    ///   thereby giving an intermediate node of the trie. This can then be used with a shortened
    ///   proof to pass the verification, which may lead to replayability.
    ///
    ///   Upstream Scroll relied on `L2MessageQueue` being a Merkle trie whose `_hash` is always a
    ///   leaf node. On DogeOS that premise no longer holds: `L2MessageQueue` is a Keccak hash chain,
    ///   so its roots are not Merkle roots and this verifier cannot validate DogeOS withdrawals.
    ///   DogeOS does not relay withdrawals through `L1ScrollMessenger`; they are paid on Dogecoin
    ///   from the bridge proof. This library is kept only for the simulated Scroll L1 contracts.
    /// @param _root The expected root node hash of the withdraw trie.
    /// @param _hash The leaf node hash of the withdraw trie.
    /// @param _nonce The index of the leaf node from left to right, starting from 0.
    /// @param _proof The concatenated merkle proof verified the leaf node.
    function verifyMerkleProof(
        bytes32 _root,
        bytes32 _hash,
        uint256 _nonce,
        bytes memory _proof
    ) internal pure returns (bool) {
        require(_proof.length % 32 == 0, "Invalid proof");
        uint256 _length = _proof.length / 32;

        for (uint256 i = 0; i < _length; i++) {
            bytes32 item;
            assembly {
                item := mload(add(add(_proof, 0x20), mul(i, 0x20)))
            }
            if (_nonce % 2 == 0) {
                _hash = _efficientHash(_hash, item);
            } else {
                _hash = _efficientHash(item, _hash);
            }
            _nonce /= 2;
        }
        return _hash == _root;
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
