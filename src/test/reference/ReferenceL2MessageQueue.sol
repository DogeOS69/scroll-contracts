// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

// REFERENCE IMPLEMENTATION (test-only). Do not modify.
//
// Verbatim copy of src/L2/predeploys/L2MessageQueue.sol at commit 28f6ca9; only the
// tree import, the contract name and its base (the pinned ReferenceAppendOnlyMerkleTree)
// differ. It is the original L2MessageQueue predeploy that L2MessageQueueEquivalence.t.sol
// runs side by side with the optimized one, and whose storage the optimized code must be
// able to take over in place (the testnet hardfork replaces the code at
// 0x5300000000000000000000000000000000000000). To confirm the copy:
//   diff <(git show 28f6ca9:src/L2/predeploys/L2MessageQueue.sol) src/test/reference/ReferenceL2MessageQueue.sol
//
// Files under src/test/**/reference/ hold such pinned implementations. They are
// compiled only by the test suite and never deployed.

import {ReferenceAppendOnlyMerkleTree} from "./ReferenceAppendOnlyMerkleTree.sol";
import {OwnableBase} from "../../libraries/common/OwnableBase.sol";

/// @title L2MessageQueue
/// @notice The original idea is from Optimism, see [OVM_L2ToL1MessagePasser](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts/contracts/L2/predeploys/OVM_L2ToL1MessagePasser.sol).
/// The L2 to L1 Message Passer is a utility contract which facilitate an L1 proof of the
/// of a message on L2. The L1 Cross Domain Messenger performs this proof in its
/// _verifyStorageProof function, which verifies the existence of the transaction hash in this
/// contract's `sentMessages` mapping.
contract ReferenceL2MessageQueue is ReferenceAppendOnlyMerkleTree, OwnableBase {
    /**********
     * Events *
     **********/

    /// @notice Emitted when a new message is added to the merkle tree.
    /// @param index The index of the corresponding message.
    /// @param messageHash The hash of the corresponding message.
    event AppendMessage(uint256 index, bytes32 messageHash);

    /*************
     * Variables *
     *************/

    /// @notice The address of L2ScrollMessenger contract.
    address public messenger;

    /***************
     * Constructor *
     ***************/

    constructor(address _owner) {
        _transferOwnership(_owner);
    }

    /// @notice Initialize the state of `L2MessageQueue`
    /// @dev You are not allowed to initialize when there are some messages appended.
    /// @param _messenger The address of messenger to update.
    function initialize(address _messenger) external onlyOwner {
        require(nextMessageIndex == 0, "cannot initialize");

        _initializeMerkleTree();

        messenger = _messenger;
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice record the message to merkle tree and compute the new root.
    /// @param _messageHash The hash of the new added message.
    function appendMessage(bytes32 _messageHash) external returns (bytes32) {
        require(msg.sender == messenger, "only messenger");

        (uint256 _currentNonce, bytes32 _currentRoot) = _appendMessageHash(_messageHash);

        // We can use the event to compute the merkle tree locally.
        emit AppendMessage(_currentNonce, _messageHash);

        return _currentRoot;
    }
}
