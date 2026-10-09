// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MoatTestBase} from "./MoatTestBase.t.sol";

// DogeOS Contracts
import {WithdrawalEnvelope} from "../../dogeos/WithdrawalEnvelope.sol";
import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {Moat} from "../../dogeos/Moat.sol";

// Scroll Contracts
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol";
import {L1ScrollMessenger} from "../../L1/L1ScrollMessenger.sol";

// Scroll Libraries
import {AddressAliasHelper} from "../../libraries/common/AddressAliasHelper.sol";
import {ScrollConstants} from "../../libraries/constants/ScrollConstants.sol";
import {IScrollMessenger} from "../../libraries/IScrollMessenger.sol";

// Helper contract that always reverts
contract RevertingReceiver {
    error AlwaysRevert();

    fallback() external payable {
        revert AlwaysRevert();
    }
}

// Helper contract that rejects value until it is switched to accept it
contract ToggleReceiver {
    error Rejected();

    bool public accepting;

    function setAccepting(bool _accepting) external {
        accepting = _accepting;
    }

    receive() external payable {
        if (!accepting) revert Rejected();
    }
}

contract L2DogeOsMessengerTest is MoatTestBase {
    L1ScrollMessenger internal _l1Messenger;

    // DogeOS Contracts Instances
    L2DogeOsMessenger internal _l2Messenger;
    Moat internal _moat;

    // Scroll Contracts Instances
    L2MessageQueue internal _l2MessageQueue;

    function setUp() public {
        // Deploy L1 contracts
        _l1Messenger = new L1ScrollMessenger(address(1), address(1), address(1), address(1), address(1));

        // Deploy L2 contracts
        _l2MessageQueue = new L2MessageQueue(address(this)); // Needs owner

        // Moat and messenger each bind the other immutably. Same order as DeployScroll:
        // the Moat proxy exists first, the messenger binds it, then the Moat implementation
        // bound to the messenger is installed and configured.
        (ProxyAdmin moatAdmin, address moatProxy) = _deployEmptyProxy();
        _l2Messenger = new L2DogeOsMessenger(
            address(_l1Messenger), // counterpart
            address(_l2MessageQueue), // messageQueue
            moatProxy // MOAT
        );
        _moat = _installMoat(
            moatAdmin,
            moatProxy,
            address(_l2Messenger),
            MoatConfig({
                owner: address(this),
                feeRecipient: address(0xfee),
                withdrawalFee: 0,
                depositFee: 0,
                minWithdrawal: 0.01 ether,
                feeExemptCaller: address(0)
            })
        );

        // Initialize L2MessageQueue to recognize our messenger
        _l2MessageQueue.initialize(address(_l2Messenger));
    }

    // Test that relayMessage reverts if the caller is not the aliased L1 messenger counterpart.
    function testRelayFromNonCounterparty() external {
        vm.expectRevert("Caller is not L1ScrollMessenger");
        // Call with _to as the Moat address, still should fail on caller check
        _l2Messenger.relayMessage({
            _from: address(this),
            _to: address(_moat),
            _value: 0,
            _nonce: 0,
            _message: new bytes(0)
        });

        // Call with _to as a non-Moat address, should also fail on caller check
        vm.expectRevert("Caller is not L1ScrollMessenger");
        _l2Messenger.relayMessage({
            _from: address(this),
            _to: address(this),
            _value: 0,
            _nonce: 1,
            _message: new bytes(0)
        });
    }

    // Test that relayMessage reverts if called by the counterparty but _to is not the Moat.
    function testRelayToNonMoatFromCounterparty() external {
        address l1Sender = address(0xabc); // Some arbitrary L1 sender
        address nonMoatTarget = address(this);
        uint256 value = 0;
        uint256 nonce = 123;
        bytes memory message = abi.encode("data");

        // Prank as the aliased L1 messenger counterpart
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));

        // Expect revert because _to is not the configured MOAT address
        vm.expectRevert(
            abi.encodeWithSelector(L2DogeOsMessenger.ErrorNotMoatAddress.selector, nonMoatTarget, address(_moat))
        );
        _l2Messenger.relayMessage({
            _from: l1Sender,
            _to: nonMoatTarget,
            _value: value,
            _nonce: nonce,
            _message: message
        });

        vm.stopPrank();
    }

    // Test that relayMessage succeeds when called by the counterparty and _to is the Moat.
    function testRelayToMoatSuccess() external {
        address l1Sender = address(0xabc);
        address finalTarget = address(0xdef);
        address targetMoat = address(_moat);
        uint256 value = 1 ether;
        uint256 nonce = 456;
        bytes32 depositID = bytes32(uint256(0x12345));
        bytes memory message = abi.encodeWithSignature("handleL1Message(address,bytes32)", finalTarget, depositID);

        // Calculate the expected hash for the RelayedMessage event
        bytes32 xDomainCalldataHash = keccak256(
            abi.encodeWithSignature(
                "relayMessage(address,address,uint256,uint256,bytes)",
                l1Sender,
                targetMoat,
                value,
                nonce,
                message
            )
        );

        // Prank as the aliased L1 messenger counterpart
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));

        // Check signature hash (topic 0) and messageHash (topic 1)
        vm.expectEmit(true, true, false, false);
        emit IScrollMessenger.RelayedMessage(xDomainCalldataHash);

        // Call relayMessage - should succeed and call the MOAT address (which does nothing)
        vm.deal(address(_l2Messenger), value); // Ensure messenger has funds to forward
        _l2Messenger.relayMessage({_from: l1Sender, _to: targetMoat, _value: value, _nonce: nonce, _message: message});

        // Verify the message was marked as executed
        assertTrue(_l2Messenger.isL1MessageExecuted(xDomainCalldataHash), "Message not executed");

        vm.stopPrank();
    }

    function testSendMessageFromNonMoat() external {
        address nonMoatCaller = address(this);
        address targetL1 = address(0x111);
        bytes memory message = abi.encode("hello");

        // Expect revert because caller is not the configured MOAT address
        vm.expectRevert(
            abi.encodeWithSelector(L2DogeOsMessenger.ErrorSenderNotMoat.selector, nonMoatCaller, address(_moat))
        );
        // Use named parameters for clarity
        _l2Messenger.sendMessage{value: 0}({_to: targetL1, _value: 0, _message: message, _gasLimit: 100000}); // Value doesn't matter for this check
    }

    // Test that the fee vault can no longer send L2 -> L1 messages directly;
    // its withdrawals must be routed through the Moat via the FeeVaultMoatAdapter.
    function testSendMessageFromFeeVaultReverts() external {
        address feeVault = address(0xfee);
        address targetL1 = address(0x111);
        bytes memory message = new bytes(0);

        vm.deal(feeVault, 1 ether);
        vm.prank(feeVault);
        vm.expectRevert(
            abi.encodeWithSelector(L2DogeOsMessenger.ErrorSenderNotMoat.selector, feeVault, address(_moat))
        );
        _l2Messenger.sendMessage{value: 1 ether}({_to: targetL1, _value: 1 ether, _message: message, _gasLimit: 0});
    }

    // Test that sendMessage succeeds when called by the Moat address.
    function testSendMessageFromMoat() external {
        address targetL1 = address(0x111);
        uint256 valueToSend = 1 ether;
        bytes memory message = WithdrawalEnvelope.encode(false); // canonical P2PKH envelope
        uint256 gasLimit = 100000;

        // Mock call coming from the MOAT address
        vm.startPrank(address(_moat));

        // Fund the Moat address so it can cover msg.value
        vm.deal(address(_moat), valueToSend);

        // Expect SentMessage event from the base messenger contract
        uint256 expectedNonce = _l2MessageQueue.nextMessageIndex();
        vm.expectEmit(true, true, true, true);
        emit IScrollMessenger.SentMessage(address(_moat), targetL1, valueToSend, expectedNonce, gasLimit, message);

        // Call the function with matching msg.value
        _l2Messenger.sendMessage{value: valueToSend}({
            _to: targetL1,
            _value: valueToSend,
            _message: message,
            _gasLimit: gasLimit
        });

        vm.stopPrank();

        // Verify nonce was incremented in the queue
        assertEq(_l2MessageQueue.nextMessageIndex(), expectedNonce + 1, "Nonce mismatch");
    }

    /// @dev The send path no longer writes messageSendTimestamp, but the withdrawal leaf must be
    ///      exactly what the upstream implementation appended: keccak256 of the relayMessage
    ///      calldata. Checked by feeding that hash to an independent queue and comparing roots.
    function testSendMessage_LeafUnchangedAndTimestampNotWritten() external {
        address targetL1 = address(0x111);
        uint256 valueToSend = 1 ether;
        bytes memory message = WithdrawalEnvelope.encode(true);
        uint256 nonce = _l2MessageQueue.nextMessageIndex();

        vm.deal(address(_moat), valueToSend);
        vm.prank(address(_moat));
        _l2Messenger.sendMessage{value: valueToSend}({
            _to: targetL1,
            _value: valueToSend,
            _message: message,
            _gasLimit: 0
        });

        bytes32 expectedLeaf = keccak256(
            abi.encodeWithSignature(
                "relayMessage(address,address,uint256,uint256,bytes)",
                address(_moat),
                targetL1,
                valueToSend,
                nonce,
                message
            )
        );
        L2MessageQueue referenceQueue = new L2MessageQueue(address(this));
        referenceQueue.initialize(address(this));
        referenceQueue.appendMessage(expectedLeaf);

        assertEq(_l2MessageQueue.messageRoot(), referenceQueue.messageRoot(), "withdrawal leaf changed");
        assertEq(_l2Messenger.messageSendTimestamp(expectedLeaf), 0, "timestamp must not be written");
    }

    function testSendMessage_Revert_ValueMismatch() external {
        vm.deal(address(_moat), 1 ether);
        vm.prank(address(_moat));
        vm.expectRevert("msg.value mismatch");
        _l2Messenger.sendMessage{value: 1 ether}({
            _to: address(0x111),
            _value: 2 ether,
            _message: WithdrawalEnvelope.encode(false),
            _gasLimit: 0
        });
    }

    // Test that the P2SH envelope is also accepted from the Moat.
    function testSendMessageFromMoatP2SHEnvelope() external {
        bytes memory message = WithdrawalEnvelope.encode(true);
        vm.deal(address(_moat), 1 ether);
        vm.prank(address(_moat));
        _l2Messenger.sendMessage{value: 1 ether}({
            _to: address(0x111),
            _value: 1 ether,
            _message: message,
            _gasLimit: 0
        });
    }

    /// @dev The envelope gate: legacy blank messages and every malformed variant must
    ///      revert even from the Moat itself. This is what guarantees exactly ONE
    ///      message representation per Dogecoin recipient type, so downstream consumers
    ///      can deterministically reconstruct the message from the withdrawal address -
    ///      and it holds even across a Moat rollback to a blank-message implementation.
    function testSendMessageFromMoatRejectsNonEnvelopeMessages() external {
        bytes[] memory bad = new bytes[](6);
        bad[0] = new bytes(0); // legacy blank (pre-v0.3.0 representation)
        bad[1] = hex"01"; // truncated
        bad[2] = hex"010000"; // overlong
        bad[3] = hex"0000"; // version 0
        bad[4] = hex"0200"; // unknown version
        bad[5] = hex"0102"; // unknown flags

        vm.deal(address(_moat), 100 ether);
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(address(_moat));
            vm.expectRevert(abi.encodeWithSelector(L2DogeOsMessenger.ErrorInvalidWithdrawalEnvelope.selector, bad[i]));
            _l2Messenger.sendMessage{value: 1 ether}({
                _to: address(0x111),
                _value: 1 ether,
                _message: bad[i],
                _gasLimit: 0
            });
        }
    }

    /// @dev Library-level pin of the canonical encodings and validity partition.
    function testEnvelopeCanonicalEncodings() external pure {
        assertEq(WithdrawalEnvelope.encode(false), hex"0100");
        assertEq(WithdrawalEnvelope.encode(true), hex"0101");
        assertTrue(WithdrawalEnvelope.isValid(hex"0100"));
        assertTrue(WithdrawalEnvelope.isValid(hex"0101"));
        assertFalse(WithdrawalEnvelope.isValid(new bytes(0)));
        assertFalse(WithdrawalEnvelope.isValid(hex"0102"));
    }

    // Test relayMessage succeeds for a zero-value deposit relay; Moat no longer uses a verifier hook.
    function testRelayToMoatSuccess_ZeroValueDeposit() external {
        address l1Sender = address(0xabc);
        address finalTarget = address(0xdef);
        address targetMoat = address(_moat);
        uint256 value = 0;
        bytes32 depositID = bytes32(uint256(0x1111));
        uint256 nonce = 999; // Use unique nonce
        bytes memory message = abi.encodeWithSignature("handleL1Message(address,bytes32)", finalTarget, depositID);

        // Calculate the expected hash for the RelayedMessage event
        bytes32 xDomainCalldataHash = keccak256(
            abi.encodeWithSignature(
                "relayMessage(address,address,uint256,uint256,bytes)",
                l1Sender,
                targetMoat,
                value,
                nonce,
                message
            )
        );

        // Prank as the aliased L1 messenger counterpart
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));

        vm.expectEmit(true, true, false, false);
        emit IScrollMessenger.RelayedMessage(xDomainCalldataHash);

        _l2Messenger.relayMessage({_from: l1Sender, _to: targetMoat, _value: value, _nonce: nonce, _message: message});

        assertTrue(_l2Messenger.isL1MessageExecuted(xDomainCalldataHash), "Message not executed");

        vm.stopPrank();
    }

    // Test relayMessage reverts when the final target call fails (via Moat)
    function testRelayToMoatTargetRevert() external {
        RevertingReceiver revertingTarget = new RevertingReceiver();

        address l1Sender = address(0xabc);
        address targetMoat = address(_moat);
        uint256 value = 1 ether;
        uint256 nonce = 789;
        bytes32 validDepositID = bytes32(uint256(0x2222)); // Valid ID

        // The message intends to call handleL1Message on Moat, which will then call the revertingTarget
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            address(revertingTarget),
            validDepositID
        );

        // Prank as the aliased L1 messenger counterpart
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));

        // Calculate the expected hash for the FailedRelayedMessage event
        bytes32 xDomainCalldataHash = keccak256(abi.encode(message));

        // Expect FailedRelayedMessage event because the call to Moat (and then the final target) reverted
        // vm.expectRevert(Moat.ErrorTargetRevert.selector); <-- Incorrect: L2ScrollMessenger catches reverts
        vm.expectEmit(false, true, false, false); // Check only messageHash topic (ignore signature)
        emit IScrollMessenger.FailedRelayedMessage(xDomainCalldataHash);

        vm.deal(address(_l2Messenger), value); // Ensure messenger has funds
        _l2Messenger.relayMessage({_from: l1Sender, _to: targetMoat, _value: value, _nonce: nonce, _message: message});

        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // RG-97: deposits relay while the L2 messenger is paused.
    //
    // `whenNotPaused` was removed from `relayMessage` only; both
    // `sendMessage` overloads keep it. The sequencer consumes an L1 message
    // even if its relay reverts, so a relay sequenced while paused left no
    // on-chain state or event, and recovery needed the node to re-inject
    // identical calldata. Now a deposit relays during a pause and executes
    // at most once; a pause still freezes withdrawals, and stopping deposits
    // means stopping L1-message inclusion at the sequencer. The last two
    // tests pin fee behavior this change does not touch; the unbounded
    // deposit fee, the other half of RG-97, is still open.
    // ------------------------------------------------------------------

    /// @dev A messenger behind a proxy so that this test contract is its
    /// owner and can pause it. The instance from `setUp` cannot be
    /// initialized because the implementation disables initializers.
    function _deployPausableStack()
        internal
        returns (
            L2DogeOsMessenger messenger,
            Moat moat,
            L2MessageQueue queue
        )
    {
        queue = new L2MessageQueue(address(this));

        // Same order as DeployScroll: the Moat proxy exists first, the
        // messenger binds its address, then the Moat implementation bound
        // to the messenger is installed.
        (ProxyAdmin moatAdmin, address moatProxy) = _deployEmptyProxy();
        L2DogeOsMessenger implementation = new L2DogeOsMessenger(address(_l1Messenger), address(queue), moatProxy);
        ProxyAdmin messengerAdmin = new ProxyAdmin();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(messengerAdmin),
            new bytes(0)
        );
        messenger = L2DogeOsMessenger(payable(address(proxy)));
        messenger.initialize(address(this)); // owner = this test contract
        moat = _installMoat(
            moatAdmin,
            moatProxy,
            address(messenger),
            MoatConfig({
                owner: address(this),
                feeRecipient: address(0xfee),
                withdrawalFee: 0,
                depositFee: 0,
                minWithdrawal: 0.01 ether,
                feeExemptCaller: address(0)
            })
        );
        queue.initialize(address(messenger));
    }

    /// @dev The hash the messenger records for a relayed message.
    function _relayHash(
        address from,
        address to,
        uint256 value,
        uint256 nonce,
        bytes memory message
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodeWithSignature(
                    "relayMessage(address,address,uint256,uint256,bytes)",
                    from,
                    to,
                    value,
                    nonce,
                    message
                )
            );
    }

    // A relay sequenced while the messenger is paused now executes: the
    // recipient is credited and the message is marked executed.
    function testRG97_PausedRelaySucceedsAndCreditsRecipient() external {
        (L2DogeOsMessenger messenger, Moat moat, ) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        uint256 value = 1 ether;
        uint256 nonce = 7;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            recipient,
            bytes32(uint256(0x97))
        );
        bytes32 relayHash = _relayHash(l1Sender, address(moat), value, nonce, message);

        messenger.setPause(true);
        assertTrue(messenger.paused(), "the messenger must be paused");
        vm.deal(address(messenger), value);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        vm.expectEmit(true, true, false, false);
        emit IScrollMessenger.RelayedMessage(relayHash);
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertTrue(messenger.isL1MessageExecuted(relayHash), "the paused relay must mark it executed");
        assertEq(recipient.balance, value, "the recipient must be credited exactly once");
        assertEq(address(moat).balance, 0, "with no deposit fee the Moat must keep nothing");
    }

    // A replay of the same message is rejected while paused and after unpause:
    // the deposit executes at most once even if the sequencer path races a pause.
    function testRG97_PausedRelayReplayRejected() external {
        (L2DogeOsMessenger messenger, Moat moat, ) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        uint256 value = 1 ether;
        uint256 nonce = 8;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            recipient,
            bytes32(uint256(0x98))
        );
        bytes32 relayHash = _relayHash(l1Sender, address(moat), value, nonce, message);
        vm.deal(address(messenger), 2 * value);

        messenger.setPause(true);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.expectRevert("Message was already successfully executed");
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        messenger.setPause(false);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        vm.expectRevert("Message was already successfully executed");
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertTrue(messenger.isL1MessageExecuted(relayHash), "the message stays executed");
        assertEq(recipient.balance, value, "the recipient is still credited exactly once");
    }

    // A pause still freezes withdrawals: both sendMessage overloads revert for
    // the Moat and nothing enters the message queue.
    function testRG97_WithdrawalStillRevertsWhilePaused() external {
        (L2DogeOsMessenger messenger, Moat moat, L2MessageQueue queue) = _deployPausableStack();
        messenger.setPause(true);

        vm.deal(address(moat), 1 ether);
        uint256 nonceBefore = queue.nextMessageIndex();
        uint256 messengerBalanceBefore = address(messenger).balance;
        vm.startPrank(address(moat));
        vm.expectRevert("Pausable: paused");
        messenger.sendMessage{value: 1 ether}({
            _to: address(0x111),
            _value: 1 ether,
            _message: WithdrawalEnvelope.encode(false),
            _gasLimit: 0
        });
        vm.expectRevert("Pausable: paused");
        messenger.sendMessage{value: 1 ether}(
            address(0x111),
            1 ether,
            WithdrawalEnvelope.encode(false),
            0,
            address(moat)
        );
        vm.stopPrank();

        assertEq(queue.nextMessageIndex(), nonceBefore, "a paused withdrawal must not enter the queue");
        assertEq(address(moat).balance, 1 ether, "the Moat keeps the withdrawal value");
        assertEq(address(messenger).balance, messengerBalanceBefore, "the messenger received nothing");
    }

    // After unpause everything behaves as before: deposits relay and
    // withdrawals enter the queue again.
    function testRG97_AfterUnpauseBehavesAsBefore() external {
        (L2DogeOsMessenger messenger, Moat moat, L2MessageQueue queue) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        uint256 value = 1 ether;
        bytes32 depositID = bytes32(uint256(0x99));
        bytes memory message = abi.encodeWithSignature("handleL1Message(address,bytes32)", recipient, depositID);

        vm.deal(address(messenger), 2 * value);
        vm.deal(address(moat), value);

        // While paused: a deposit still credits.
        messenger.setPause(true);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: 9, _message: message});
        vm.stopPrank();
        assertEq(recipient.balance, value, "the deposit credits while paused");

        // While paused: a withdrawal still reverts.
        vm.startPrank(address(moat));
        vm.expectRevert("Pausable: paused");
        messenger.sendMessage{value: value}({
            _to: address(0x111),
            _value: value,
            _message: WithdrawalEnvelope.encode(false),
            _gasLimit: 0
        });
        vm.stopPrank();

        // After unpause: both directions behave as before.
        messenger.setPause(false);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: 10, _message: message});
        vm.stopPrank();
        assertEq(recipient.balance, 2 * value, "the post-unpause deposit credits");

        uint256 nonceBefore = queue.nextMessageIndex();
        vm.startPrank(address(moat));
        messenger.sendMessage{value: value}({
            _to: address(0x111),
            _value: value,
            _message: WithdrawalEnvelope.encode(false),
            _gasLimit: 0
        });
        vm.stopPrank();
        assertEq(queue.nextMessageIndex(), nonceBefore + 1, "the withdrawal enters the queue after unpause");
    }

    // A relay that fails while paused stays retryable: the target rejects
    // value, so the relay emits FailedRelayedMessage, is not marked executed
    // and keeps the value in the messenger. A retry with the same hash, still
    // while paused, then succeeds, and a further replay is rejected.
    function testRG97_PausedFailedRelayCanBeRetriedWhilePaused() external {
        (L2DogeOsMessenger messenger, Moat moat, ) = _deployPausableStack();
        ToggleReceiver recipient = new ToggleReceiver();
        address l1Sender = address(0xabc);
        address l1Alias = AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger));
        uint256 value = 1 ether;
        uint256 nonce = 13;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            address(recipient),
            bytes32(uint256(0x9d))
        );
        bytes32 relayHash = _relayHash(l1Sender, address(moat), value, nonce, message);

        messenger.setPause(true);
        vm.deal(address(messenger), value);

        // The target rejects value: the relay fails but does not revert.
        vm.prank(l1Alias);
        vm.expectEmit(true, false, false, false, address(messenger));
        emit IScrollMessenger.FailedRelayedMessage(relayHash);
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});

        assertFalse(messenger.isL1MessageExecuted(relayHash), "a failed relay must not be marked executed");
        assertEq(address(messenger).balance, value, "the messenger keeps the value of a failed relay");
        assertEq(address(recipient).balance, 0, "the target received nothing");
        assertEq(
            messenger.xDomainMessageSender(),
            ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER,
            "xDomainMessageSender is reset after a failed relay"
        );

        // The retry with the same hash succeeds while still paused.
        recipient.setAccepting(true);
        assertTrue(messenger.paused(), "the messenger is still paused");
        vm.prank(l1Alias);
        vm.expectEmit(true, false, false, false, address(messenger));
        emit IScrollMessenger.RelayedMessage(relayHash);
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});

        assertTrue(messenger.isL1MessageExecuted(relayHash), "the retry marks the message executed");
        assertEq(address(recipient).balance, value, "the retry credits the target");
        assertEq(address(messenger).balance, 0, "the value left the messenger exactly once");

        // A further replay is rejected.
        vm.prank(l1Alias);
        vm.expectRevert("Message was already successfully executed");
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
    }

    // KNOWN-BAD PIN: `setDepositFee` has no upper bound (fee half of RG-97,
    // still open). With a fee at or above the deposit, the relay succeeds and
    // marks the message executed, but the whole deposit is held as Moat fee
    // and the target is never called; `sweepFees` later pays it all to the fee
    // recipient. When a fee cap lands, flip this test to expect `setDepositFee`
    // to revert above the cap rather than keeping it passing.
    function testKnownIssue_UnboundedDepositFeeSwallowsTheWholeDeposit() external {
        (L2DogeOsMessenger messenger, Moat moat, ) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        address feeRecipient = address(0xfee);
        uint256 value = 1 ether;
        uint256 nonce = 11;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            recipient,
            bytes32(uint256(0x9b))
        );
        bytes32 relayHash = _relayHash(l1Sender, address(moat), value, nonce, message);

        moat.setDepositFee(type(uint256).max); // accepted: there is no cap
        assertEq(moat.depositFee(), type(uint256).max);

        vm.deal(address(messenger), value);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertTrue(messenger.isL1MessageExecuted(relayHash), "the relay reports success");
        assertEq(recipient.balance, 0, "the recipient is not credited");
        assertEq(address(moat).balance, value, "the whole deposit is held as fee");
        assertEq(feeRecipient.balance, 0, "nothing is paid out before a sweep");

        assertEq(moat.sweepFees(), value, "the sweep pays the held fee");
        assertEq(feeRecipient.balance, value, "the whole deposit went to the fee recipient");
    }

    // A fee recipient that rejects value does not fail deposits: since the
    // fee-hold change (#65), fees are held by the Moat instead of paid inside
    // the relay, so the deposit still credits and the message is marked
    // executed. Only `sweepFees` reverts, until the owner changes the recipient.
    function testDeposit_RevertingFeeRecipientDoesNotFailRelay() external {
        (L2DogeOsMessenger messenger, Moat moat, ) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        uint256 value = 1 ether;
        uint256 nonce = 12;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            recipient,
            bytes32(uint256(0x9c))
        );
        bytes32 relayHash = _relayHash(l1Sender, address(moat), value, nonce, message);

        moat.setFeeRecipient(address(new RevertingReceiver()));
        moat.setDepositFee(1);

        vm.deal(address(messenger), value);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertTrue(messenger.isL1MessageExecuted(relayHash), "the deposit is not failed by the fee recipient");
        assertEq(recipient.balance, value - 1, "the recipient is credited minus the held fee");
        assertEq(address(moat).balance, 1, "the fee is held, not paid");
        vm.expectRevert(Moat.ErrorFeeTransferFailed.selector);
        moat.sweepFees();
    }
}
