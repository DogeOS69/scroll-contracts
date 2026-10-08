// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {L2ScrollMessenger} from "../L2/L2ScrollMessenger.sol";
import {ScrollMessengerBase} from "../libraries/ScrollMessengerBase.sol";
import {IScrollMessenger} from "../libraries/IScrollMessenger.sol";
import {L2MessageQueue} from "../L2/predeploys/L2MessageQueue.sol";
import {AddressAliasHelper} from "../libraries/common/AddressAliasHelper.sol";
import {ScrollConstants} from "../libraries/constants/ScrollConstants.sol";

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

    /// @notice Whether relays also check the per-hash `isL1MessageExecuted` mapping that
    /// recorded successes before replay protection moved to the per-nonce bitmap.
    /// @dev False for a messenger that starts with this implementation. True for one upgraded
    /// in place from a pre-bitmap implementation, and for every later upgrade of it: its old
    /// successes are only in the per-hash mapping. The deploy and upgrade scripts derive the
    /// required value from the live proxy (scripts/deterministic/LegacyReplayCheck.sol) and
    /// refuse to turn it off. It costs those networks one extra storage read per relay.
    bool public immutable LEGACY_REPLAY_CHECK;

    /// @dev Transaction-local relay context, owned by the proxy under delegatecall.
    /// Encoded as uint160(sender) + 1, so address(0) is distinct from idle (0).
    bytes32 private constant RELAY_SENDER_SLOT = keccak256("dogeos.messenger.transient.relay-sender");

    // --- Storage --- //

    /// @dev Bitmap of successfully relayed L1 message nonces: bit `n & 0xff` of word `n >> 8`.
    /// On DogeOS every L1 message is derived by the circuits with nonce == L1 queue index, so
    /// nonces are unique and dense and one word covers 256 consecutive deposits. Appended
    /// after L2ScrollMessenger's storage.
    mapping(uint256 => uint256) private _executedNonceBitmap;

    // --- Constructor --- //

    /**
     * @notice Constructor
     * @param _counterpart The address of the L1 counterpart messenger.
     * @param _messageQueue The address of the L2 Message Queue predeploy.
     * @param _moat The address of the DogeOS Moat contract.
     * @param _legacyReplayCheck See {LEGACY_REPLAY_CHECK}.
     */
    constructor(
        address _counterpart,
        address _messageQueue,
        address _moat,
        bool _legacyReplayCheck
    ) L2ScrollMessenger(_counterpart, _messageQueue) {
        if (_moat == address(0)) {
            revert ErrorZeroMoatAddress();
        }
        MOAT = _moat;
        LEGACY_REPLAY_CHECK = _legacyReplayCheck;
    }

    // --- Views --- //

    /// @notice The cross-domain sender during a relay, or the legacy idle value otherwise.
    /// @dev Keep the pre-initialization getter and old proxy slot intact. The relay hot path
    /// uses the initialized sentinel directly and never reads or writes that old slot.
    function xDomainMessageSender() public view override(ScrollMessengerBase, IScrollMessenger) returns (address) {
        uint256 encoded = _relaySender();
        return encoded == 0 ? super.xDomainMessageSender() : address(uint160(encoded - 1));
    }

    function _relaySender() private view returns (uint256 encoded) {
        bytes32 slot = RELAY_SENDER_SLOT;
        assembly {
            encoded := tload(slot)
        }
    }

    function _setRelaySender(uint256 encoded) private {
        bytes32 slot = RELAY_SENDER_SLOT;
        assembly {
            tstore(slot, encoded)
        }
    }

    /**
     * @notice Whether the L1 message with this nonce (== L1 queue index) was relayed successfully
     * by this implementation.
     * @dev Reads only the per-nonce bitmap. Successes recorded before the upgrade are in the
     * frozen per-hash {isL1MessageExecuted} mapping, which new relays no longer write.
     * @param _nonce The L1 message nonce.
     * @return True if a relay with this nonce succeeded.
     */
    function isL1MessageNonceExecuted(uint256 _nonce) external view returns (bool) {
        return (_executedNonceBitmap[_nonce >> 8] >> (_nonce & 0xff)) & 1 == 1;
    }

    // --- Overridden Public Functions --- //

    /**
     * @notice Relays an L1 -> L2 message (a Dogecoin deposit) to the Moat.
     * @dev Same as L2ScrollMessenger.relayMessage, except that replay protection is keyed by
     * nonce in a bitmap instead of by message hash in a mapping: the upstream version writes a
     * fresh storage slot (~22k gas) per deposit, the bitmap one slot per 256 deposits. On
     * DogeOS the nonce is the L1 queue index, which the circuits fix per Dogecoin deposit, so
     * a nonce identifies a message; a different message reusing a relayed nonce is rejected.
     * As before, only a successful relay is recorded, so a failed one stays retryable.
     * @param _from The L1 sender address.
     * @param _to The L2 target; must be the Moat.
     * @param _value The value to forward.
     * @param _nonce The L1 message nonce (L1 queue index).
     * @param _message The calldata for the target.
     */
    function relayMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _nonce,
        bytes memory _message
    ) external override whenNotPaused {
        // It is impossible to deploy a contract with the same address, reentrance is prevented in nature.
        require(AddressAliasHelper.undoL1ToL2Alias(_msgSender()) == counterpart, "Caller is not L1ScrollMessenger");

        bytes32 _xDomainCalldataHash = keccak256(_encodeXDomainCalldata(_from, _to, _value, _nonce, _message));

        uint256 _word = _nonce >> 8;
        uint256 _bit = 1 << (_nonce & 0xff);
        require(_executedNonceBitmap[_word] & _bit == 0, "Message was already successfully executed");
        if (LEGACY_REPLAY_CHECK) {
            require(!isL1MessageExecuted[_xDomainCalldataHash], "Message was already successfully executed");
        }

        if (_callMoat(_from, _to, _value, _message)) {
            _executedNonceBitmap[_word] |= _bit;
            emit RelayedMessage(_xDomainCalldataHash);
        } else {
            emit FailedRelayedMessage(_xDomainCalldataHash);
        }
    }

    // --- Internal Functions --- //

    /**
     * @dev Executes a relayed message: the checks and target call of
     * L2ScrollMessenger._executeMessage, restricted to the Moat, without its per-hash
     * bookkeeping (relayMessage records success in the bitmap). The inherited
     * `_executeMessage` is no longer reachable: its only caller was the upstream relayMessage.
     * @return success Whether the call to the Moat succeeded.
     */
    function _callMoat(
        address _from,
        address _to,
        uint256 _value,
        bytes memory _message
    ) private returns (bool success) {
        // Only allow messages destined for the Moat address.
        if (_to != MOAT) {
            revert ErrorNotMoatAddress(_to, MOAT);
        }
        // @note check more `_to` address to avoid attack in the future when we add more gateways.
        require(_to != messageQueue, "Forbid to call message queue");
        _validateTargetAddress(_to);

        // @note This usually will never happen, just in case.
        // Initialized proxies are idle at DEFAULT_XDOMAIN_MESSAGE_SENDER. Check
        // the transient context directly so the hot path never reads the old slot.
        uint256 encoded = uint256(uint160(_from)) + 1;
        require(
            _from != ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER && _relaySender() != encoded,
            "Invalid message sender"
        );

        _setRelaySender(encoded);
        // solhint-disable-next-line avoid-low-level-calls
        // no reentrancy risk, only alias(l1ScrollMessenger) can call relayMessage.
        // Calls MOAT (== _to, checked above) so the destination is visibly fixed.
        // slither-disable-next-line reentrancy-eth
        (success, ) = MOAT.call{value: _value}(_message);
        // Clear even after a caught target revert; another relay may run in this transaction.
        _setRelaySender(0);
    }

    // --- Overridden Internal Functions --- //

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
