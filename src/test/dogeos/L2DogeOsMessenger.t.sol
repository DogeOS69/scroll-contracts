// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {Test} from "forge-std/Test.sol";

// DogeOS Contracts
import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {Moat} from "../../dogeos/Moat.sol";
import {BasculeMockVerifier} from "../../dogeos/BasculeMockVerifier.sol";
import {IBasculeVerifier} from "../../dogeos/IBasculeVerifier.sol";

// Scroll Contracts
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol";
import {L1ScrollMessenger} from "../../L1/L1ScrollMessenger.sol";

// Scroll Libraries
import {AddressAliasHelper} from "../../libraries/common/AddressAliasHelper.sol";
import {IScrollMessenger} from "../../libraries/IScrollMessenger.sol";

// OpenZeppelin
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Helper contract that always reverts
contract RevertingReceiver {
    error AlwaysRevert();

    fallback() external payable {
        revert AlwaysRevert();
    }
}

contract L2DogeOsMessengerTest is Test {
    L1ScrollMessenger internal _l1Messenger;

    // DogeOS Contracts Instances
    L2DogeOsMessenger internal _l2Messenger;
    Moat internal _moat;
    BasculeMockVerifier internal _basculeVerifier;

    // Scroll Contracts Instances
    L2MessageQueue internal _l2MessageQueue;

    function setUp() public {
        // Deploy L1 contracts
        _l1Messenger = new L1ScrollMessenger(address(1), address(1), address(1), address(1), address(1));

        // Deploy L2 contracts
        _l2MessageQueue = new L2MessageQueue(address(this)); // Needs owner

        // Deploy DogeOS contracts
        _basculeVerifier = new BasculeMockVerifier();

        // Moat needs owner at deployment
        address moatOwner = address(this);
        _moat = new Moat();
        _moat.initialize(moatOwner);

        // Messenger needs Moat address at deployment
        _l2Messenger = new L2DogeOsMessenger(
            address(_l1Messenger), // counterpart
            address(_l2MessageQueue), // messageQueue
            address(_moat), // initialMoat
            address(0xfee) // _feeVault (Assuming address(0xfee) is suitable placeholder)
        );

        // Link Moat back to Messenger (requires owner call)
        _moat.updateMessenger(address(_l2Messenger));

        // Initialize L2MessageQueue to recognize our messenger
        _l2MessageQueue.initialize(address(_l2Messenger));

        // Configure Moat (using owner = address(this))
        // DO NOT set basculeVerifier in this test suite. Moat.handleL1Message will skip verification.
        // Verification logic involving Moat should be tested in Moat.t.sol.
        _moat.setFeeRecipient(address(0xfee));
        _moat.setBascule(address(_basculeVerifier));
        // Set other Moat params as needed
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

    // Test that sendMessage succeeds when called by the Moat address.
    function testSendMessageFromMoat() external {
        address targetL1 = address(0x111);
        uint256 valueToSend = 1 ether;
        bytes memory message = abi.encode("hello from moat");
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

    // Test relayMessage reverts when Bascule verification fails (via Moat)
    function testRelayToMoatBasculeFailure(uint8 failCase) external {
        vm.assume(failCase <= 1);
        address l1Sender = address(0xabc);
        address finalTarget = address(0xdef);
        address targetMoat = address(_moat);
        uint256 value;
        bytes32 depositID;
        uint256 nonce = 999; // Use unique nonce

        if (failCase == 0) {
            // Fail because of bad deposit ID
            value = 1 ether;
            depositID = _basculeVerifier.REJECT_DEPOSIT_ID(); // Access via the instance
        } else {
            // Fail because of zero value
            value = 0;
            depositID = bytes32(uint256(0x1111)); // Any non-reject ID
        }

        bytes memory message = abi.encodeWithSignature("handleL1Message(address,bytes32)", finalTarget, depositID);

        // Calculate the expected hash for the FailedRelayedMessage event
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

        // Expect FailedRelayedMessage event because the underlying call to Moat (and then Bascule) reverted
        // vm.expectRevert(BasculeMockVerifier.ErrorMockRejection.selector); <-- Incorrect: L2ScrollMessenger catches reverts
        vm.expectEmit(false, true, false, false); // Check only messageHash topic (ignore signature)
        emit IScrollMessenger.FailedRelayedMessage(xDomainCalldataHash);

        if (value > 0) {
            vm.deal(address(_l2Messenger), value); // Ensure messenger has funds if needed
        }
        _l2Messenger.relayMessage({_from: l1Sender, _to: targetMoat, _value: value, _nonce: nonce, _message: message});

        vm.stopPrank();
    }

    // Test relayMessage reverts when the final target call fails (via Moat)
    function testRelayToMoatTargetRevert() external {
        RevertingReceiver revertingTarget = new RevertingReceiver();

        address l1Sender = address(0xabc);
        address targetMoat = address(_moat);
        uint256 value = 1 ether; // Non-zero value to pass Bascule
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
    // RG-97: what a paused messenger, an unbounded deposit fee and a
    // reverting fee recipient do to a deposit.
    //
    // These tests pin current behaviour. They do not say it is right: the
    // tracker row asks for a decision (remove `whenNotPaused` from relay,
    // or hold deposit sequencing before any pause, and bound the fee).
    // What they cannot show is the sequencer side: an L1 message that
    // reverts on L2 still consumes its queue index, and DogeOS has no replay
    // path. So a message that fails here is not relayed again unless
    // someone sends it again.
    // ------------------------------------------------------------------

    /// @dev A messenger behind a proxy so that this test contract is its
    /// owner and can pause it. The instance from `setUp` cannot be
    /// initialized because the implementation disables initializers.
    function _deployPausableStack() internal returns (L2DogeOsMessenger messenger, Moat moat) {
        L2MessageQueue queue = new L2MessageQueue(address(this));
        moat = new Moat();
        moat.initialize(address(this));

        L2DogeOsMessenger implementation = new L2DogeOsMessenger(
            address(_l1Messenger),
            address(queue),
            address(moat),
            address(0xfee)
        );
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            new bytes(0)
        );
        messenger = L2DogeOsMessenger(payable(address(proxy)));
        messenger.initialize(address(_l1Messenger)); // owner = this test contract
        moat.updateMessenger(address(messenger));
        queue.initialize(address(messenger));
        moat.setFeeRecipient(address(0xfee));
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

    // A relay while the messenger is paused reverts as a whole. It leaves no
    // "executed" mark and no failed-message event, and the recipient gets nothing.
    function testRG97_PausedRelayRevertsAndLeavesNoRecord() external {
        (L2DogeOsMessenger messenger, Moat moat) = _deployPausableStack();
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
        vm.deal(address(messenger), value);
        vm.recordLogs();
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        vm.expectRevert("Pausable: paused");
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertFalse(messenger.isL1MessageExecuted(relayHash), "a paused relay must not mark it executed");
        assertEq(recipient.balance, 0, "the recipient must not be credited");
        assertEq(vm.getRecordedLogs().length, 0, "a paused relay must not emit any relay event");
    }

    // Control for the test above: the contract itself does not consume the
    // message. After unpause the same message relays and credits the recipient.
    // Whether it is ever relayed again depends on the sequencer sending it again.
    function testRG97_TheSameMessageRelaysAfterUnpause() external {
        (L2DogeOsMessenger messenger, Moat moat) = _deployPausableStack();
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
        vm.deal(address(messenger), value);

        messenger.setPause(true);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        vm.expectRevert("Pausable: paused");
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        messenger.setPause(false);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertTrue(messenger.isL1MessageExecuted(relayHash), "the retried message executes");
        assertEq(recipient.balance, value, "the recipient is credited by the retry");
    }

    // `setDepositFee` has no upper bound. With a fee at or above the deposit,
    // the relay succeeds and marks the message executed, but all of the value
    // goes to the fee recipient and the target is never called.
    function testRG97_AnUnboundedDepositFeeSwallowsTheWholeDeposit() external {
        (L2DogeOsMessenger messenger, Moat moat) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        address feeRecipient = address(0xfee);
        uint256 value = 1 ether;
        uint256 nonce = 9;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            recipient,
            bytes32(uint256(0x99))
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
        assertEq(feeRecipient.balance, value, "the whole deposit went to the fee recipient");
    }

    // A fee recipient that rejects value makes every deposit fail. The messenger
    // records FailedRelayedMessage, does not mark the message executed, and the
    // recipient gets nothing. Nothing in this repository sends it again.
    function testRG97_ARevertingFeeRecipientFailsTheDeposit() external {
        (L2DogeOsMessenger messenger, Moat moat) = _deployPausableStack();
        address l1Sender = address(0xabc);
        address recipient = address(0xdef);
        uint256 value = 1 ether;
        uint256 nonce = 10;
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes32)",
            recipient,
            bytes32(uint256(0x9a))
        );
        bytes32 relayHash = _relayHash(l1Sender, address(moat), value, nonce, message);

        moat.setFeeRecipient(address(new RevertingReceiver()));
        moat.setDepositFee(1);

        vm.deal(address(messenger), value);
        vm.startPrank(AddressAliasHelper.applyL1ToL2Alias(address(_l1Messenger)));
        vm.expectEmit(true, true, false, false);
        emit IScrollMessenger.FailedRelayedMessage(relayHash);
        messenger.relayMessage({_from: l1Sender, _to: address(moat), _value: value, _nonce: nonce, _message: message});
        vm.stopPrank();

        assertFalse(messenger.isL1MessageExecuted(relayHash), "the failed message is not marked executed");
        assertEq(recipient.balance, 0, "the recipient is not credited");
    }
}
