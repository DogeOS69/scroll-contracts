// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {AppendOnlyHashChain} from "../../libraries/common/AppendOnlyHashChain.sol";
import {OwnableBase} from "../../libraries/common/OwnableBase.sol";

/// @title L2MessageQueue
/// @notice Commits L2 withdrawal messages in order with keccak256(previousHash || messageHash).
contract L2MessageQueue is AppendOnlyHashChain, OwnableBase {
    /**********
     * Events *
     **********/

    /// @notice Emitted when a new message is added to the hash chain.
    /// @param index The index of the corresponding message.
    /// @param messageHash The hash of the corresponding message.
    event AppendMessage(uint256 index, bytes32 messageHash);

    /*************
     * Variables *
     *************/

    /// @notice The authorized L2 messenger.
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

        messenger = _messenger;
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice record the message to hash chain and compute the new root.
    /// @param _messageHash The hash of the new added message.
    function appendMessage(bytes32 _messageHash) external returns (bytes32) {
        require(msg.sender == messenger, "only messenger");

        (uint256 _currentNonce, bytes32 _currentRoot) = _appendMessageHash(_messageHash);

        // The events reproduce the hash chain locally, given its seed: zero for a queue
        // created at genesis, the checkpoint root for one upgraded by code replacement.
        emit AppendMessage(_currentNonce, _messageHash);

        return _currentRoot;
    }
}
