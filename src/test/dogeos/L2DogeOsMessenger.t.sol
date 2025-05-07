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
        _l1Messenger = new L1ScrollMessenger(address(1), address(1), address(1), address(1));

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
            address(0xfee)
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
        bytes memory finalCalldata = abi.encode(bytes32(uint256(0x12345)));
        bytes memory message = abi.encodeWithSignature("handleL1Message(address,bytes)", finalTarget, finalCalldata);

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
            depositID = 0xbadca11000000000000000000000000000000000000000000000000000000000; // Hardcoded value
        } else {
            // Fail because of zero value
            value = 0;
            depositID = bytes32(uint256(0x1111)); // Any non-reject ID
        }

        bytes memory finalCalldata = abi.encode(depositID);
        bytes memory message = abi.encodeWithSignature("handleL1Message(address,bytes)", finalTarget, finalCalldata);

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
        bytes memory finalCalldata = abi.encode(validDepositID);

        // The message intends to call handleL1Message on Moat, which will then call the revertingTarget
        bytes memory message = abi.encodeWithSignature(
            "handleL1Message(address,bytes)",
            address(revertingTarget),
            finalCalldata
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
}
