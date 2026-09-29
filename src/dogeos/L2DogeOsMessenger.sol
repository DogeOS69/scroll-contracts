// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {L2ScrollMessenger} from "../L2/L2ScrollMessenger.sol";
import {L2MessageQueue} from "../L2/predeploys/L2MessageQueue.sol";

import {WithdrawalEnvelope} from "./WithdrawalEnvelope.sol";

// Potentially add import for Moat contract here

/**
 * @title L2DogeOsMessenger
 * @notice A custom L2 messenger for DogeOS, inheriting from L2ScrollMessenger.
 * It modifies the standard behavior to interact with the DogeOS Moat contract.
 */
contract L2DogeOsMessenger is L2ScrollMessenger {
    // --- Errors --- //
    error ErrorNotMoatAddress(address provided, address expected);
    error ErrorSenderNotMoat(address sender, address expected);
    error ErrorZeroMoatAddress();
    error ErrorInvalidWithdrawalEnvelope(bytes message);

    // --- State Variables --- //

    /// @notice The immutable address of the DogeOS Moat contract.
    /// @dev Only messages directed to this address will be executed.
    address public immutable MOAT;

    // --- Constructor --- //

    /**
     * @notice Constructor
     * @param _counterpart The address of the L1 counterpart messenger.
     * @param _messageQueue The address of the L2 Message Queue predeploy.
     * @param _moat The address of the DogeOS Moat contract.
     */
    constructor(
        address _counterpart,
        address _messageQueue,
        address _moat
    ) L2ScrollMessenger(_counterpart, _messageQueue) {
        if (_moat == address(0)) {
            revert ErrorZeroMoatAddress();
        }
        MOAT = _moat;
    }

    // --- Overridden Internal Functions --- //

    /**
     * @notice Overrides the L1 -> L2 message execution logic.
     * Ensures that messages relayed via this messenger are only executed if targeting the MOAT address.
     * @param _from The L1 sender address.
     * @param _to The originally intended L2 recipient address.
     * @param _value The ETH value sent with the message.
     * @param _message The encoded calldata intended for the target (_to).
     * @param _xDomainCalldataHash The hash of the cross-domain message calldata.
     */
    function _executeMessage(
        address _from,
        address _to,
        uint256 _value,
        bytes memory _message,
        bytes32 _xDomainCalldataHash
    ) internal virtual override {
        // Only allow messages destined for the Moat address.
        if (_to != MOAT) {
            revert ErrorNotMoatAddress(_to, MOAT);
        }

        // If the message is for the Moat, proceed with original execution logic.
        super._executeMessage({
            _from: _from,
            _to: _to,
            _value: _value,
            _message: _message,
            _xDomainCalldataHash: _xDomainCalldataHash
        });
    }

    /**
     * @notice Overrides the L2 -> L1 message sending logic.
     * Only the Moat may send L2 -> L1 messages, and every message must be exactly a
     * valid v1 withdrawal envelope (P2PKH 0x0100 / P2SH 0x0101) - so every withdrawal
     * seen on L1 has a predictable sender, ONE deterministic message representation
     * per Dogecoin recipient type, and an 8-decimal-aligned value. Downstream
     * consumers can reconstruct the exact message bytes (and thus the message hash)
     * from the Dogecoin address used in the withdrawal alone.
     *
     * Legacy pre-v0.3.0 blank messages are rejected here, not just avoided by the
     * Moat: even a Moat rollback to an implementation that sends empty messages
     * cannot reintroduce a second P2PKH representation (such sends revert).
     * Fee vault withdrawals are routed through the Moat via the FeeVaultMoatAdapter.
     * @param _to The L1 recipient address.
     * @param _value The ETH value to send with the message.
     * @param _message The message calldata; must be a valid v1 withdrawal envelope.
     * @param _gasLimit The gas limit for L1 execution.
     */
    function _sendMessage(
        address _to,
        uint256 _value,
        bytes memory _message,
        uint256 _gasLimit
    ) internal virtual override nonReentrant {
        // Require that the caller is the MOAT contract.
        if (msg.sender != MOAT) {
            revert ErrorSenderNotMoat(msg.sender, MOAT);
        }

        // Require the canonical v1 envelope - no blank/legacy messages.
        if (!WithdrawalEnvelope.isValid(_message)) {
            revert ErrorInvalidWithdrawalEnvelope(_message);
        }

        // Same as L2ScrollMessenger._sendMessage, except that `messageSendTimestamp` is no
        // longer written: a fresh 22.1k-gas SSTORE per withdrawal that nothing reads, on L2 or
        // off-chain. Its only use was the "Duplicated message" check, which cannot fire: the
        // hash commits to `_nonce`, a fresh L2MessageQueue index per message. The mapping and
        // its getter stay for storage-layout compatibility and keep the timestamps of
        // messages sent before this upgrade; for newer messages the getter returns 0.
        require(msg.value == _value, "msg.value mismatch");

        uint256 _nonce = L2MessageQueue(messageQueue).nextMessageIndex();
        bytes32 _xDomainCalldataHash = keccak256(_encodeXDomainCalldata(_msgSender(), _to, _value, _nonce, _message));

        L2MessageQueue(messageQueue).appendMessage(_xDomainCalldataHash);

        emit SentMessage(_msgSender(), _to, _value, _nonce, _gasLimit, _message);
    }
}
