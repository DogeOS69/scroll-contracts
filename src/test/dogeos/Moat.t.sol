// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

// Target contract
import {Moat} from "../../dogeos/Moat.sol";

// Interfaces & Mocks
import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {BasculeMockVerifier} from "../../dogeos/BasculeMockVerifier.sol";
import {IBasculeVerifier} from "../../dogeos/IBasculeVerifier.sol";
import {IL2ScrollMessenger} from "../../L2/IL2ScrollMessenger.sol"; // Interface for mock
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol"; // Needed for L2DogeOsMessenger constructor
import {RevertingReceiver} from "./L2DogeOsMessenger.t.sol"; // Reuse helper
import {ScrollMessengerBase} from "../../libraries/ScrollMessengerBase.sol"; // Import base for mock

// Simple target contract for handleL1Message tests
contract SimpleTarget {
    event Executed(bytes data, uint256 value);

    // Use fallback to accept raw depositID calldata from Moat
    fallback() external payable {
        emit Executed(msg.data, msg.value);
    }
}

/**
 * @title MockScrollMessenger
 * @notice Mocks basic messenger behavior (sendMessage) for Moat testing.
 * Inherits from ScrollMessengerBase to satisfy type checks but provides minimal implementation.
 */
contract MockScrollMessenger is ScrollMessengerBase {
    event MockSendMessageCalled(
        address sender,
        address target,
        uint256 value,
        bytes message,
        uint256 gasLimit,
        uint256 msgValue
    );

    address public lastSender;
    address public lastTarget;
    uint256 public lastValue;
    bytes public lastMessage;
    uint256 public lastGasLimit;
    uint256 public lastMsgValue;

    // Constructor matching ScrollMessengerBase
    constructor(address _counterpart) ScrollMessengerBase(_counterpart) {}

    // Implement the required sendMessage interface function
    // No override keyword needed as ScrollMessengerBase doesn't implement it directly
    function sendMessage(
        address _to,
        uint256 _value,
        bytes calldata _message,
        uint256 _gasLimit
    )
        public
        payable
        /* virtual override removed */
        whenNotPaused
    {
        // Record call parameters
        lastSender = msg.sender;
        lastTarget = _to;
        lastValue = _value;
        lastMessage = _message;
        lastGasLimit = _gasLimit;
        lastMsgValue = msg.value;

        emit MockSendMessageCalled(msg.sender, _to, _value, _message, _gasLimit, msg.value);
    }

    // Need to implement the other sendMessage variant from IScrollMessenger
    // even if Moat doesn't use it, to satisfy the compiler.
    function sendMessage(
        address _to,
        uint256 _value,
        bytes calldata _message,
        uint256 _gasLimit,
        address /* refundAddress */
    )
        public
        payable
        /* virtual override removed */
        whenNotPaused
    {
        // Just call the other implementation for simplicity in the mock
        this.sendMessage{value: msg.value}(_to, _value, _message, _gasLimit);
    }

    // Implement relayMessage (required by IScrollMessenger, but likely unused by Moat tests)
    function relayMessage(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external whenNotPaused {
        revert("MockScrollMessenger: relayMessage not implemented");
    }

    // Implement dropMessage (required by IScrollMessenger, but likely unused by Moat tests)
    function dropMessage(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external whenNotPaused {
        revert("MockScrollMessenger: dropMessage not implemented");
    }
}

contract MoatTest is Test {
    // Contracts
    Moat internal _moat;
    BasculeMockVerifier internal _basculeVerifier;
    MockScrollMessenger internal _mockMessenger; // Changed type
    // L2MessageQueue internal _l2MessageQueue; // No longer needed for mock constructor

    // Addresses
    address internal _owner = address(0x1);
    address payable internal _feeRecipient = payable(address(0xfee));
    address internal _user = address(0x2);
    address internal _l1Counterpart = address(0xbeef);

    // Constants
    uint256 internal constant _INITIAL_FEE = 0.01 ether;
    uint256 internal constant _INITIAL_MIN_WITHDRAWAL = 0.1 ether;

    function setUp() public {
        // Deploy Mocks & Dependencies
        _basculeVerifier = new BasculeMockVerifier();
        // _l2MessageQueue = new L2MessageQueue(_owner); // No longer needed

        // Deploy Moat (owned by _owner)
        vm.prank(_owner);
        _moat = new Moat();
        _moat.initialize(_owner);

        // Deploy Mock Messenger (simpler constructor)
        _mockMessenger = new MockScrollMessenger(
            _l1Counterpart
            // No longer needs message queue or moat address
        );

        // Configure Moat (as owner)
        vm.startPrank(_owner);
        _moat.updateMessenger(address(_mockMessenger));
        _moat.setBascule(address(_basculeVerifier));
        _moat.setFeeRecipient(_feeRecipient);
        _moat.setFee(_INITIAL_FEE);
        _moat.setMinWithdrawal(_INITIAL_MIN_WITHDRAWAL);
        vm.stopPrank();

        // Deal initial balances if needed for specific tests later
        vm.deal(_user, 10 ether);
    }

    // --- Tests: Setters --- //

    function testUpdateMessenger_Success() external {
        address newMessenger = address(0xabcd);
        address oldMessenger = address(_mockMessenger);

        vm.prank(_owner);
        vm.expectEmit(true, true, false, false); // oldMessenger, newMessenger are indexed
        emit Moat.MessengerUpdated(oldMessenger, newMessenger);
        _moat.updateMessenger(newMessenger);

        assertEq(_moat.messenger(), newMessenger, "Messenger address should be updated");
    }

    function testUpdateMessenger_Revert_NotOwner() external {
        address newMessenger = address(0xabcd);
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.updateMessenger(newMessenger);
    }

    function testUpdateMessenger_Revert_ZeroAddress() external {
        address newMessenger = address(0);
        vm.prank(_owner);
        vm.expectRevert(Moat.ErrorZeroAddress.selector);
        _moat.updateMessenger(newMessenger);
    }

    function testSetFee_Success() external {
        uint256 newFee = 0.05 ether;
        uint256 oldFee = _moat.withdrawalFee();

        vm.prank(_owner);
        vm.expectEmit(false, false, false, false); // No indexed args
        emit Moat.FeeUpdated(oldFee, newFee);
        _moat.setFee(newFee);

        assertEq(_moat.withdrawalFee(), newFee, "Fee should be updated");
    }

    function testSetFee_Revert_NotOwner() external {
        uint256 newFee = 0.05 ether;
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setFee(newFee);
    }

    function testSetMinWithdrawal_Success() external {
        uint256 newMin = 0.5 ether;
        uint256 oldMin = _moat.minWithdrawalAmount();

        vm.prank(_owner);
        vm.expectEmit(false, false, false, false); // No indexed args
        emit Moat.MinWithdrawalUpdated(oldMin, newMin);
        _moat.setMinWithdrawal(newMin);

        assertEq(_moat.minWithdrawalAmount(), newMin, "Min withdrawal should be updated");
    }

    function testSetMinWithdrawal_Revert_NotOwner() external {
        uint256 newMin = 0.5 ether;
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setMinWithdrawal(newMin);
    }

    function testSetFeeRecipient_Success() external {
        address newRecip = address(0xabcd);
        address oldRecip = _moat.feeRecipient();

        vm.prank(_owner);
        vm.expectEmit(true, true, false, false); // oldRecip, newRecip are indexed
        emit Moat.FeeRecipientUpdated(oldRecip, newRecip);
        _moat.setFeeRecipient(newRecip);

        assertEq(_moat.feeRecipient(), newRecip, "Fee recipient should be updated");
    }

    function testSetFeeRecipient_Revert_NotOwner() external {
        address newRecip = address(0xabcd);
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setFeeRecipient(newRecip);
    }

    function testSetFeeRecipient_Revert_ZeroAddress() external {
        address newRecip = address(0);
        vm.prank(_owner);
        vm.expectRevert(Moat.ErrorZeroAddress.selector);
        _moat.setFeeRecipient(newRecip);
    }

    function testSetBascule_Success() external {
        address newVerifier = address(0xdcba);
        address oldVerifier = _moat.basculeVerifier();

        vm.prank(_owner);
        vm.expectEmit(true, true, false, false); // oldVerifier, newVerifier are indexed
        emit Moat.BasculeVerifierUpdated(oldVerifier, newVerifier);
        _moat.setBascule(newVerifier);

        assertEq(_moat.basculeVerifier(), newVerifier, "Bascule verifier should be updated");
    }

    function testSetBascule_Success_ZeroAddress() external {
        // Allowed to disable verification by setting to address(0)
        address newVerifier = address(0);
        address oldVerifier = _moat.basculeVerifier();

        vm.prank(_owner);
        vm.expectEmit(true, true, false, false); // oldVerifier, newVerifier are indexed
        emit Moat.BasculeVerifierUpdated(oldVerifier, newVerifier);
        _moat.setBascule(newVerifier);

        assertEq(_moat.basculeVerifier(), newVerifier, "Bascule verifier should be updated to address(0)");
    }

    function testSetBascule_Revert_NotOwner() external {
        address newVerifier = address(0xdcba);
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setBascule(newVerifier);
    }

    // --- Tests: withdrawToL1 ---

    function testWithdrawToL1_Success() external {
        address targetL1 = address(0x1111); // L1 recipient
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee(); // _INITIAL_FEE
        uint256 totalValue = amountToSend + fee;

        // Pre-state checks
        uint256 feeRecipBalanceBefore = _feeRecipient.balance;
        assertTrue(fee > 0, "Test requires non-zero fee");
        assertTrue(_feeRecipient != address(0), "Test requires non-zero fee recipient");
        assertTrue(amountToSend >= _moat.minWithdrawalAmount(), "Amount must meet minimum");

        // Expect events (Order matters!)
        // 1. MockSendMessageCalled from Mock Messenger (emitted during Moat's call to messenger.sendMessage)
        vm.expectEmit(false, false, false, false); // No indexed args
        emit MockScrollMessenger.MockSendMessageCalled(
            address(_moat), // Sender should be Moat
            targetL1,
            amountToSend, // Value should be amount AFTER fee
            bytes(""), // Empty message
            0, // Gas limit 0
            amountToSend // msg.value to messenger is amount AFTER fee
        );
        // 2. WithdrawalQueued from Moat (emitted at the end of Moat.withdrawToL1)
        vm.expectEmit(true, true, false, false); // sender, target indexed
        emit Moat.WithdrawalQueued(_user, targetL1, amountToSend, fee);

        // Perform the withdrawal
        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        // Post-state checks
        // Check fee recipient balance
        uint256 feeRecipBalanceAfter = _feeRecipient.balance;
        assertEq(feeRecipBalanceAfter, feeRecipBalanceBefore + fee, "Fee recipient balance mismatch");

        // Check mock messenger state (redundant with event check, but good practice)
        assertEq(_mockMessenger.lastSender(), address(_moat), "Mock: sender mismatch");
        assertEq(_mockMessenger.lastTarget(), targetL1, "Mock: target mismatch");
        assertEq(_mockMessenger.lastValue(), amountToSend, "Mock: value mismatch");
        assertEq(_mockMessenger.lastMessage().length, 0, "Mock: message length mismatch");
        assertEq(_mockMessenger.lastGasLimit(), 0, "Mock: gas limit mismatch");
        assertEq(_mockMessenger.lastMsgValue(), amountToSend, "Mock: msg.value mismatch");
    }

    function testWithdrawToL1_Revert_FeeNotCovered() external {
        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();

        // Test case 1: Sending exactly the fee amount
        vm.prank(_user);
        vm.expectRevert(Moat.ErrorFeeNotCovered.selector);
        _moat.withdrawToL1{value: fee}(targetL1);

        // Test case 2: Sending less than the fee amount (if fee > 0)
        if (fee > 0) {
            vm.prank(_user);
            vm.expectRevert(Moat.ErrorFeeNotCovered.selector);
            _moat.withdrawToL1{value: fee - 1}(targetL1);
        }

        // Test case 3: Sending zero (if fee > 0)
        if (fee > 0) {
            vm.prank(_user);
            vm.expectRevert(Moat.ErrorFeeNotCovered.selector);
            _moat.withdrawToL1{value: 0}(targetL1);
        }
    }

    function testWithdrawToL1_Revert_BelowMinimum() external {
        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();
        uint256 minAmount = _moat.minWithdrawalAmount();

        assertTrue(minAmount > 0, "Test requires non-zero min amount");

        // Calculate value to send so that (value - fee) is exactly one less than minAmount
        uint256 valueToSend = minAmount + fee - 1;

        // Ensure the valueToSend is still greater than the fee
        if (valueToSend > fee) {
            vm.prank(_user);
            vm.expectRevert(Moat.ErrorBelowMinimumWithdrawal.selector);
            _moat.withdrawToL1{value: valueToSend}(targetL1);
        }

        // Also test sending just the fee + minimum amount - 1 wei
        // (This assumes fee > 0, otherwise it's covered by FeeNotCovered test)
        if (fee > 0) {
            uint256 barelyEnoughValue = fee + minAmount; // This should succeed
            uint256 notEnoughValue = barelyEnoughValue - 1; // This should fail

            // Sanity check: ensure barelyEnoughValue works
            // Need to reset mock state if we call it twice
            vm.startPrank(_owner);
            _mockMessenger = new MockScrollMessenger(_l1Counterpart);
            _moat.updateMessenger(address(_mockMessenger));
            vm.stopPrank();

            vm.prank(_user);
            // No revert expected here
            _moat.withdrawToL1{value: barelyEnoughValue}(targetL1);

            // Now check the failure case
            vm.prank(_user);
            vm.expectRevert(Moat.ErrorBelowMinimumWithdrawal.selector);
            _moat.withdrawToL1{value: notEnoughValue}(targetL1);
        }
    }

    /* // Removing flawed test - cannot set fee recipient to zero
    function testWithdrawToL1_Success_ZeroFeeRecipient() external {
        // Set fee recipient to address(0)
        vm.prank(_owner);
        _moat.setFeeRecipient(address(0));
        vm.stopPrank();

        address targetL1 = address(0x1111);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee(); // Still use the fee for calculation
        uint256 totalValue = amountToSend + fee;

        assertTrue(fee > 0, "Test requires non-zero fee");
        assertTrue(amountToSend >= _moat.minWithdrawalAmount(), "Amount must meet minimum");

        // No balance change expected for address(0)

        // Expect events (same as success, except no balance change)
        vm.expectEmit(true, true, false, false);
        emit Moat.WithdrawalQueued(_user, targetL1, amountToSend, fee);
        vm.expectEmit(false, false, false, false); // No indexed args
        emit MockScrollMessenger.MockSendMessageCalled(
            address(_moat), targetL1, amountToSend, bytes(""), 0, amountToSend
        );

        // Perform the withdrawal
        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        // Check mock messenger state
        assertEq(_mockMessenger.lastSender(), address(_moat), "Mock: sender mismatch");
        assertEq(_mockMessenger.lastTarget(), targetL1, "Mock: target mismatch");
        assertEq(_mockMessenger.lastValue(), amountToSend, "Mock: value mismatch");
        // Balance of address(0) cannot be checked directly, but no revert occurred.
    }
    */

    function testWithdrawToL1_Success_ZeroFee() external {
        // Set fee to 0
        vm.prank(_owner);
        _moat.setFee(0);
        vm.stopPrank();

        address targetL1 = address(0x1111);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = 0;
        uint256 totalValue = amountToSend; // No fee

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;
        assertTrue(_feeRecipient != address(0), "Test requires non-zero fee recipient");
        assertTrue(amountToSend >= _moat.minWithdrawalAmount(), "Amount must meet minimum");

        // Expect events (Order matters!)
        // 1. MockSendMessageCalled from Mock Messenger
        vm.expectEmit(false, false, false, false); // No indexed args
        emit MockScrollMessenger.MockSendMessageCalled(
            address(_moat),
            targetL1,
            amountToSend,
            bytes(""),
            0,
            amountToSend // Full amount sent to messenger
        );
        // 2. WithdrawalQueued from Moat
        vm.expectEmit(true, true, false, false);
        emit Moat.WithdrawalQueued(_user, targetL1, amountToSend, fee);

        // Perform the withdrawal
        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        // Post-state checks
        uint256 feeRecipBalanceAfter = _feeRecipient.balance;
        assertEq(feeRecipBalanceAfter, feeRecipBalanceBefore, "Fee recipient balance should not change");

        // Check mock messenger state
        assertEq(_mockMessenger.lastSender(), address(_moat), "Mock: sender mismatch");
        assertEq(_mockMessenger.lastTarget(), targetL1, "Mock: target mismatch");
        assertEq(_mockMessenger.lastValue(), amountToSend, "Mock: value mismatch");
        assertEq(_mockMessenger.lastMsgValue(), amountToSend, "Mock: msg.value mismatch");
    }

    // --- Test handleL1Message ---

    function testHandleL1Message_Revert_NotMessenger() external {
        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111));
        uint256 value = 1 ether;

        // Call from non-messenger address (_user)
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(Moat.ErrorOnlyMessenger.selector, _user, address(_mockMessenger)));
        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}(
            /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
    }

    function testHandleL1Message_Success() external {
        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111)); // Use a valid ID
        uint256 value = 1 ether; // Use non-zero value

        // Ensure verifier is set
        assertTrue(_moat.basculeVerifier() != address(0), "Test requires bascule verifier enabled");

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event
        vm.expectEmit(true, true, false, false); // Check sender, target, amount
        emit Moat.DepositReceived(address(_mockMessenger), address(target), value);

        // Expect the target contract to emit its event via fallback with empty data
        vm.expectEmit(false, false, false, false);
        emit SimpleTarget.Executed(bytes(""), value); // Expect empty bytes

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}(
            /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
        vm.stopPrank();
    }

    function testHandleL1Message_Revert_BasculeVerificationFails(uint8 failCase) external {
        vm.assume(failCase <= 1);
        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue;
        uint256 value;

        if (failCase == 0) {
            // Fail because of bad deposit ID
            depositIDValue = _basculeVerifier.REJECT_DEPOSIT_ID(); // Use constant from mock
            value = 1 ether; // Non-zero value
        } else {
            // Fail because of zero value
            depositIDValue = bytes32(uint256(0x1111)); // Any valid ID
            value = 0;
        }

        // Ensure verifier is set
        assertTrue(_moat.basculeVerifier() != address(0), "Test requires bascule verifier enabled");

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event (even on revert, if it happens before Bascule check)
        // vm.expectEmit(true, true, false, false); // Check sender, target, amount
        // emit Moat.DepositReceived(address(_mockMessenger), address(target), value);

        // Expect revert from the mock verifier
        vm.expectRevert(BasculeMockVerifier.ErrorMockRejection.selector);

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}(
            /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
        vm.stopPrank();
    }

    function testHandleL1Message_BasculeDisabled() external {
        SimpleTarget target = new SimpleTarget();
        // Use the normally rejecting deposit ID
        bytes32 depositIDValue = _basculeVerifier.REJECT_DEPOSIT_ID(); // Use constant from mock
        uint256 value = 1 ether; // Non-zero value

        // Disable Bascule verifier
        vm.prank(_owner);
        _moat.setBascule(address(0));
        vm.stopPrank();
        assertTrue(_moat.basculeVerifier() == address(0), "Test requires bascule verifier disabled");

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event
        vm.expectEmit(true, true, false, false); // Check sender, target, amount
        emit Moat.DepositReceived(address(_mockMessenger), address(target), value);

        // Expect the target contract to emit its event via fallback (verification skipped)
        vm.expectEmit(false, false, false, false);
        emit SimpleTarget.Executed(bytes(""), value); // Expect empty bytes

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}(
            /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
        vm.stopPrank();
    }

    function testHandleL1Message_Revert_TargetRevert() external {
        RevertingReceiver target = new RevertingReceiver(); // Use the reverting helper
        bytes32 depositIDValue = bytes32(uint256(0x1111)); // Use a valid ID
        uint256 value = 1 ether; // Use non-zero value

        // Ensure verifier is set
        assertTrue(_moat.basculeVerifier() != address(0), "Test requires bascule verifier enabled");

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event
        vm.expectEmit(true, true, false, false); // Check sender, target, amount
        emit Moat.DepositReceived(address(_mockMessenger), address(target), value);

        // Expect Moat's ErrorTargetRevert
        vm.expectRevert(Moat.ErrorTargetRevert.selector);

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}(
            /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
        vm.stopPrank();
    }

    /* // Removing this test as the length check is gone
    function testHandleL1Message_Revert_InvalidDataLength() external {
        SimpleTarget target = new SimpleTarget();
        // address l1Sender = address(0xaaaa); // Removed unused variable
        bytes memory invalidData = abi.encodePacked(bytes32(uint256(0x1111)), bytes1(0x00)); // 33 bytes
        uint256 value = 1 ether;

        // Ensure verifier is set
        assertTrue(_moat.basculeVerifier() != address(0), "Test requires bascule verifier enabled");

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect Moat's ErrorInvalidDataLength
        vm.expectRevert(abi.encodeWithSelector(Moat.ErrorInvalidDataLength.selector, invalidData.length));

        // Update call signature
        _moat.handleL1Message{value: value}(address(target), invalidData); // This call is now invalid anyway
        vm.stopPrank();
    }
    */
}
