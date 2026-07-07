// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

// Target contract
import {Moat} from "../../dogeos/Moat.sol";
import {DogeAddressLib} from "../../dogeos/DogeAddressLib.sol";

// Interfaces & Mocks
import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
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

// Helper contract that rejects ETH transfers (for testing fee transfer failures)
contract RejectingFeeRecipient {
    error RejectETH();

    // This contract always reverts when receiving ETH
    receive() external payable {
        revert RejectETH();
    }

    fallback() external payable {
        revert RejectETH();
    }
}

// Helper contract for testing DogeAddressLib (wraps internal functions for external calls)
contract DogeAddressLibWrapper {
    function decode(string calldata addr) external pure returns (bytes1 prefix, bytes20 payload) {
        return DogeAddressLib.decode(addr);
    }

    function decodeChecked(
        string calldata addr,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix
    ) external pure returns (bool isP2SH, bytes20 payload) {
        return DogeAddressLib.decodeChecked(addr, p2pkhPrefix, p2shPrefix);
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
    MockScrollMessenger internal _mockMessenger; // Changed type
    DogeAddressLibWrapper internal _libWrapper; // For testing library revert cases
    // L2MessageQueue internal _l2MessageQueue; // No longer needed for mock constructor

    // Addresses
    address internal _owner = address(0x1);
    address payable internal _feeRecipient = payable(address(0xfee));
    address internal _user = address(0x2);
    address internal _l1Counterpart = address(0xbeef);

    // Constants
    uint256 internal constant _INITIAL_FEE = 0.01 ether;
    uint256 internal constant _INITIAL_MIN_WITHDRAWAL = 0.1 ether;

    // Dogecoin network prefixes (mainnet)
    bytes1 internal constant _P2PKH_PREFIX = bytes1(0x1e);
    bytes1 internal constant _P2SH_PREFIX = bytes1(0x16);

    function setUp() public {
        // Deploy Mocks & Dependencies
        // _l2MessageQueue = new L2MessageQueue(_owner); // No longer needed

        // Deploy Moat (owned by _owner) with mainnet prefixes
        vm.prank(_owner);
        _moat = new Moat(_P2PKH_PREFIX, _P2SH_PREFIX);
        _moat.initialize(_owner);

        // Deploy Mock Messenger (simpler constructor)
        _mockMessenger = new MockScrollMessenger(
            _l1Counterpart
            // No longer needs message queue or moat address
        );

        // Deploy library wrapper for revert testing
        _libWrapper = new DogeAddressLibWrapper();

        // Configure Moat (as owner)
        vm.startPrank(_owner);
        _moat.updateMessenger(address(_mockMessenger));
        _moat.setFeeRecipient(_feeRecipient);
        _moat.setWithdrawalFee(_INITIAL_FEE);
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

    function testSetWithdrawalFee_Success() external {
        uint256 newFee = 0.05 ether;
        uint256 oldFee = _moat.withdrawalFee();

        vm.prank(_owner);
        vm.expectEmit(false, false, false, false); // No indexed args
        emit Moat.WithdrawalFeeUpdated(oldFee, newFee);
        _moat.setWithdrawalFee(newFee);

        assertEq(_moat.withdrawalFee(), newFee, "Fee should be updated");
    }

    function testSetWithdrawalFee_Revert_NotOwner() external {
        uint256 newFee = 0.05 ether;
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setWithdrawalFee(newFee);
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

    function testSetMinWithdrawal_Revert_TooSmall() external {
        uint256 newMin = 0.01 ether - 1 wei;
        vm.prank(_owner);
        vm.expectRevert(Moat.ErrorInvalidMinWithdrawal.selector);
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

    // --- Tests: Deposit Fee Setters --- //

    function testSetDepositFee_Success() external {
        uint256 newFee = 0.05 ether;
        uint256 oldFee = _moat.depositFee();

        vm.prank(_owner);
        vm.expectEmit(false, false, false, false); // No indexed args
        emit Moat.DepositFeeUpdated(oldFee, newFee);
        _moat.setDepositFee(newFee);

        assertEq(_moat.depositFee(), newFee, "Deposit fee should be updated");
    }

    function testSetDepositFee_Revert_NotOwner() external {
        uint256 newFee = 0.05 ether;
        vm.prank(_user); // Non-owner
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setDepositFee(newFee);
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

        // Expected envelope: version=1, flags=0 (P2PKH)
        bytes memory expectedEnvelope = new bytes(2);
        expectedEnvelope[0] = bytes1(uint8(1)); // version
        expectedEnvelope[1] = bytes1(uint8(0)); // flags (P2PKH)

        // Expect events (Order matters!)
        // 1. MockSendMessageCalled from Mock Messenger (emitted during Moat's call to messenger.sendMessage)
        vm.expectEmit(false, false, false, false); // No indexed args
        emit MockScrollMessenger.MockSendMessageCalled(
            address(_moat), // Sender should be Moat
            targetL1,
            amountToSend, // Value should be amount AFTER fee
            expectedEnvelope, // Envelope with version=1, flags=0
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
        assertEq(_mockMessenger.lastMessage().length, 2, "Mock: message length should be 2 (envelope)");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Mock: envelope version mismatch");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(0)), "Mock: envelope flags mismatch (should be P2PKH)");
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
        _moat.setWithdrawalFee(0);
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
        _moat.handleL1Message{value: value}( /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
    }

    function testHandleL1Message_Success() external {
        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111)); // Use a valid ID
        uint256 value = 1 ether; // Use non-zero value

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event
        vm.expectEmit(true, true, false, false); // Check sender, target, amount
        emit Moat.DepositReceived(address(_mockMessenger), address(target), value, 0);

        // Expect the target contract to emit its event via fallback with empty data
        vm.expectEmit(false, false, false, false);
        emit SimpleTarget.Executed(bytes(""), value); // Expect empty bytes

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}( /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
        vm.stopPrank();
    }

    function testHandleL1Message_Success_UnverifiedDepositId() external {
        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0xffff));
        uint256 value = 1 ether; // Non-zero value

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event
        vm.expectEmit(true, true, false, false); // Check sender, target, amount
        emit Moat.DepositReceived(address(_mockMessenger), address(target), value, 0);

        // Expect the target contract to emit its event via fallback.
        vm.expectEmit(false, false, false, false);
        emit SimpleTarget.Executed(bytes(""), value); // Expect empty bytes

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}( /* _target */
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

        // Call from the mock messenger address
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), value);

        // Expect the Moat event
        vm.expectEmit(true, true, false, false); // Check sender, target, amount
        emit Moat.DepositReceived(address(_mockMessenger), address(target), value, 0);

        // Expect Moat's ErrorTargetRevert
        vm.expectRevert(Moat.ErrorTargetRevert.selector);

        // Call with bytes32 deposit ID
        _moat.handleL1Message{value: value}( /* _target */
            address(target),
            /* _depositID */
            depositIDValue
        );
        vm.stopPrank();
    }

    // --- Tests: Deposit Fee Logic in handleL1Message --- //

    function testHandleL1Message_WithDepositFee_Success() external {
        // Setup: Configure deposit fee
        uint256 depositFee = 0.01 ether;
        uint256 depositAmount = 1 ether;

        vm.startPrank(_owner);
        _moat.setDepositFee(depositFee);
        vm.stopPrank();

        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111));

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;
        uint256 expectedAmountToTarget = depositAmount - depositFee;

        // Call from the mock messenger
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), depositAmount);

        // Expect events
        vm.expectEmit(true, true, false, false);
        emit Moat.DepositReceived(address(_mockMessenger), address(target), depositAmount, depositFee);

        vm.expectEmit(false, false, false, false);
        emit SimpleTarget.Executed(bytes(""), expectedAmountToTarget);

        _moat.handleL1Message{value: depositAmount}(address(target), depositIDValue);
        vm.stopPrank();

        // Verify fee collection
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + depositFee, "Fee recipient should receive deposit fee");
    }

    function testHandleL1Message_FullFeeCollection_Success() external {
        // Setup: Configure deposit fee higher than deposit amount
        uint256 depositFee = 1 ether;
        uint256 depositAmount = 0.5 ether; // Less than fee

        vm.startPrank(_owner);
        _moat.setDepositFee(depositFee);
        vm.stopPrank();

        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111));

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        // Call from the mock messenger
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), depositAmount);

        // Expect events (no target execution since all funds go to fee)
        vm.expectEmit(true, true, false, false);
        emit Moat.DepositReceived(address(_mockMessenger), address(target), depositAmount, depositAmount);

        // No SimpleTarget.Executed event expected

        _moat.handleL1Message{value: depositAmount}(address(target), depositIDValue);
        vm.stopPrank();

        // Verify all funds went to fee recipient
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + depositAmount, "All funds should go to fee recipient");
    }

    function testHandleL1Message_ZeroDepositFee_Success() external {
        // Setup: Zero deposit fee (backward compatibility)
        uint256 depositAmount = 1 ether;

        vm.startPrank(_owner);
        _moat.setDepositFee(0);
        vm.stopPrank();

        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111));

        // Call from the mock messenger
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), depositAmount);

        // Expect only DepositReceived and target execution (no fee collection)
        vm.expectEmit(true, true, false, false);
        emit Moat.DepositReceived(address(_mockMessenger), address(target), depositAmount, 0);

        vm.expectEmit(false, false, false, false);
        emit SimpleTarget.Executed(bytes(""), depositAmount);

        _moat.handleL1Message{value: depositAmount}(address(target), depositIDValue);
        vm.stopPrank();
    }

    // --- Tests: Fee Transfer Failure Handling --- //

    function testHandleL1Message_Revert_DepositFeeTransferFailed() external {
        // Setup: Configure deposit fee with rejecting recipient
        uint256 depositFee = 0.01 ether;
        uint256 depositAmount = 1 ether;

        RejectingFeeRecipient rejectingRecipient = new RejectingFeeRecipient();

        vm.startPrank(_owner);
        _moat.setDepositFee(depositFee);
        _moat.setFeeRecipient(address(rejectingRecipient));
        vm.stopPrank();

        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111));

        // Call from the mock messenger
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), depositAmount);

        // Expect revert due to fee transfer failure
        vm.expectRevert(Moat.ErrorFeeTransferFailed.selector);
        _moat.handleL1Message{value: depositAmount}(address(target), depositIDValue);
        vm.stopPrank();
    }

    function testHandleL1Message_Revert_FullDepositFeeTransferFailed() external {
        // Setup: Configure deposit fee higher than deposit amount with rejecting recipient
        uint256 depositFee = 1 ether;
        uint256 depositAmount = 0.5 ether; // Less than fee

        RejectingFeeRecipient rejectingRecipient = new RejectingFeeRecipient();

        vm.startPrank(_owner);
        _moat.setDepositFee(depositFee);
        _moat.setFeeRecipient(address(rejectingRecipient));
        vm.stopPrank();

        SimpleTarget target = new SimpleTarget();
        bytes32 depositIDValue = bytes32(uint256(0x1111));

        // Call from the mock messenger
        vm.startPrank(address(_mockMessenger));
        vm.deal(address(_mockMessenger), depositAmount);

        // Expect revert due to fee transfer failure (full amount to fee)
        vm.expectRevert(Moat.ErrorFeeTransferFailed.selector);
        _moat.handleL1Message{value: depositAmount}(address(target), depositIDValue);
        vm.stopPrank();
    }

    function testWithdrawToL1_Revert_WithdrawalFeeTransferFailed() external {
        // Setup: Configure withdrawal with rejecting fee recipient
        address targetL1 = address(0x1111);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee(); // Use existing fee
        uint256 totalValue = amountToSend + fee;

        RejectingFeeRecipient rejectingRecipient = new RejectingFeeRecipient();

        vm.startPrank(_owner);
        _moat.setFeeRecipient(address(rejectingRecipient));
        vm.stopPrank();

        // Attempt withdrawal - should fail on fee transfer
        vm.prank(_user);
        vm.expectRevert(Moat.ErrorFeeTransferFailed.selector);
        _moat.withdrawToL1{value: totalValue}(targetL1);
    }

    // --- Tests: P2SH/P2PKH Envelope Encoding --- //

    function testWithdrawToP2PKH_EnvelopeEncoding() external {
        address targetL1 = address(0x1111);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        vm.prank(_user);
        _moat.withdrawToP2PKH{value: totalValue}(targetL1);

        // Verify envelope: version=1, flags=0 (P2PKH)
        assertEq(_mockMessenger.lastMessage().length, 2, "Envelope length should be 2");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Envelope version should be 1");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(0)), "Envelope flags should be 0 (P2PKH)");
        assertEq(_mockMessenger.lastTarget(), targetL1, "Target mismatch");
    }

    function testWithdrawToP2SH_EnvelopeEncoding() external {
        address targetL1 = address(0x2222);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        vm.prank(_user);
        _moat.withdrawToP2SH{value: totalValue}(targetL1);

        // Verify envelope: version=1, flags=1 (P2SH)
        assertEq(_mockMessenger.lastMessage().length, 2, "Envelope length should be 2");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Envelope version should be 1");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(1)), "Envelope flags should be 1 (P2SH)");
        assertEq(_mockMessenger.lastTarget(), targetL1, "Target mismatch");
    }

    function testWithdrawToL1_EmitsV1Envelope() external {
        // withdrawToL1 is now an alias for withdrawToP2PKH
        address targetL1 = address(0x3333);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        // Verify envelope: version=1, flags=0 (P2PKH)
        assertEq(_mockMessenger.lastMessage().length, 2, "Envelope length should be 2");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Envelope version should be 1");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(0)), "Envelope flags should be 0 (P2PKH)");
    }

    // --- Tests: Prefix Configuration --- //

    function testPrefixImmutables() external view {
        assertEq(_moat.P2PKH_PREFIX(), _P2PKH_PREFIX, "P2PKH prefix mismatch");
        assertEq(_moat.P2SH_PREFIX(), _P2SH_PREFIX, "P2SH prefix mismatch");
    }

    // --- Tests: withdrawToP2PKH Fee Logic --- //

    function testWithdrawToP2PKH_FeeLogic() external {
        address targetL1 = address(0x1111);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.prank(_user);
        _moat.withdrawToP2PKH{value: totalValue}(targetL1);

        // Verify fee was transferred
        uint256 feeRecipBalanceAfter = _feeRecipient.balance;
        assertEq(feeRecipBalanceAfter, feeRecipBalanceBefore + fee, "Fee recipient balance mismatch");

        // Verify amount sent to messenger
        assertEq(_mockMessenger.lastValue(), amountToSend, "Value sent to messenger mismatch");
    }

    function testWithdrawToP2PKH_Revert_FeeNotCovered() external {
        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorFeeNotCovered.selector);
        _moat.withdrawToP2PKH{value: fee}(targetL1);
    }

    function testWithdrawToP2PKH_Revert_BelowMinimum() external {
        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();
        uint256 minAmount = _moat.minWithdrawalAmount();

        // Send just under the minimum after fee
        uint256 valueToSend = minAmount + fee - 1;

        if (valueToSend > fee) {
            vm.prank(_user);
            vm.expectRevert(Moat.ErrorBelowMinimumWithdrawal.selector);
            _moat.withdrawToP2PKH{value: valueToSend}(targetL1);
        }
    }

    // --- Tests: withdrawToP2SH Fee Logic --- //

    function testWithdrawToP2SH_FeeLogic() external {
        address targetL1 = address(0x2222);
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.prank(_user);
        _moat.withdrawToP2SH{value: totalValue}(targetL1);

        // Verify fee was transferred
        uint256 feeRecipBalanceAfter = _feeRecipient.balance;
        assertEq(feeRecipBalanceAfter, feeRecipBalanceBefore + fee, "Fee recipient balance mismatch");

        // Verify amount sent to messenger
        assertEq(_mockMessenger.lastValue(), amountToSend, "Value sent to messenger mismatch");
    }

    function testWithdrawToP2SH_Revert_FeeNotCovered() external {
        address targetL1 = address(0x2222);
        uint256 fee = _moat.withdrawalFee();

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorFeeNotCovered.selector);
        _moat.withdrawToP2SH{value: fee}(targetL1);
    }

    // --- Tests: Messenger Not Configured --- //

    function testWithdrawToP2PKH_Revert_MessengerNotConfigured() external {
        // Deploy a new Moat without configuring the messenger
        Moat unconfiguredMoat = new Moat(_P2PKH_PREFIX, _P2SH_PREFIX);
        unconfiguredMoat.initialize(_owner);

        address targetL1 = address(0x1111);
        uint256 totalValue = 1 ether;

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorZeroAddress.selector);
        unconfiguredMoat.withdrawToP2PKH{value: totalValue}(targetL1);
    }

    function testWithdrawToP2SH_Revert_MessengerNotConfigured() external {
        // Deploy a new Moat without configuring the messenger
        Moat unconfiguredMoat = new Moat(_P2PKH_PREFIX, _P2SH_PREFIX);
        unconfiguredMoat.initialize(_owner);

        address targetL1 = address(0x2222);
        uint256 totalValue = 1 ether;

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorZeroAddress.selector);
        unconfiguredMoat.withdrawToP2SH{value: totalValue}(targetL1);
    }

    function testWithdrawToL1_Revert_MessengerNotConfigured() external {
        // Deploy a new Moat without configuring the messenger
        Moat unconfiguredMoat = new Moat(_P2PKH_PREFIX, _P2SH_PREFIX);
        unconfiguredMoat.initialize(_owner);

        address targetL1 = address(0x3333);
        uint256 totalValue = 1 ether;

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorZeroAddress.selector);
        unconfiguredMoat.withdrawToL1{value: totalValue}(targetL1);
    }

    // --- Tests: Satoshi Flooring --- //

    function testWithdrawToL1_FloorsDustIntoFee() external {
        address targetL1 = address(0x1111);
        uint256 satoshi = _moat.SATOSHI_TO_WEI();
        uint256 fee = _moat.withdrawalFee();
        uint256 amountAligned = 0.5 ether; // multiple of SATOSHI_TO_WEI
        uint256 dust = 123456789; // sub-satoshi remainder
        assertTrue(dust < satoshi, "dust must be sub-satoshi");
        uint256 totalValue = amountAligned + dust + fee;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        // WithdrawalQueued must carry the floored amount and the dust-inclusive fee.
        vm.expectEmit(true, true, false, true);
        emit Moat.WithdrawalQueued(_user, targetL1, amountAligned, fee + dust);

        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Messenger value should be floored");
        assertEq(_mockMessenger.lastMsgValue(), amountAligned, "Messenger msg.value should be floored");
        assertEq(
            _feeRecipient.balance,
            feeRecipBalanceBefore + fee + dust,
            "Fee recipient should receive base fee plus dust"
        );
    }

    function testWithdrawToL1_NoDustWhenSatoshiAligned() external {
        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();
        uint256 amountAligned = 0.5 ether;
        uint256 totalValue = amountAligned + fee;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.expectEmit(true, true, false, true);
        emit Moat.WithdrawalQueued(_user, targetL1, amountAligned, fee);

        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Messenger value should be unchanged");
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + fee, "Fee recipient should receive base fee only");
    }

    function testWithdrawToL1_DustGoesToFeeRecipient_ZeroBaseFee() external {
        vm.prank(_owner);
        _moat.setWithdrawalFee(0);

        address targetL1 = address(0x1111);
        uint256 amountAligned = 0.5 ether;
        uint256 dust = 123;
        uint256 totalValue = amountAligned + dust;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.expectEmit(true, true, false, true);
        emit Moat.WithdrawalQueued(_user, targetL1, amountAligned, dust);

        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Messenger value should be floored");
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + dust, "Fee recipient should receive only dust");
    }

    function testWithdrawToL1_Revert_FloorsToZero() external {
        // Fresh Moat: fee and min both unset (0), so only the zero guard can catch this.
        Moat freshMoat = new Moat(_P2PKH_PREFIX, _P2SH_PREFIX);
        freshMoat.initialize(_owner);
        vm.prank(_owner);
        freshMoat.updateMessenger(address(_mockMessenger));

        address targetL1 = address(0x1111);
        uint256 subSatoshiValue = _moat.SATOSHI_TO_WEI() - 1;

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorBelowMinimumWithdrawal.selector);
        freshMoat.withdrawToL1{value: subSatoshiValue}(targetL1);
    }

    function testWithdrawToL1_Revert_BelowMinimumAfterFlooring() external {
        // A minimum that is not satoshi-aligned: pre-floor amounts can pass it while
        // their floored value does not.
        uint256 minAmount = 0.1 ether + 1;
        vm.prank(_owner);
        _moat.setMinWithdrawal(minAmount);

        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();
        uint256 dust = 5e9;
        uint256 totalValue = fee + 0.1 ether + dust; // pre-floor amount >= min, post-floor < min

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorBelowMinimumWithdrawal.selector);
        _moat.withdrawToL1{value: totalValue}(targetL1);
    }

    function testFuzz_WithdrawAmountSatoshiAligned(uint256 rawValue) external {
        uint256 satoshi = _moat.SATOSHI_TO_WEI();
        uint256 fee = _moat.withdrawalFee();
        uint256 minAmount = _moat.minWithdrawalAmount();
        uint256 totalValue = bound(rawValue, fee + minAmount + satoshi, 10 ether);

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.prank(_user);
        _moat.withdrawToL1{value: totalValue}(address(0x1111));

        uint256 sentAmount = _mockMessenger.lastValue();
        uint256 feeCollected = _feeRecipient.balance - feeRecipBalanceBefore;

        assertEq(sentAmount % satoshi, 0, "Withdrawal amount must be satoshi-aligned");
        assertTrue(sentAmount >= minAmount, "Withdrawal amount must meet the minimum");
        assertEq(sentAmount + feeCollected, totalValue, "Value must be conserved");
    }

    // --- Tests: Fee Exemption --- //

    function testSetFeeExempt_Success() external {
        address account = address(0xabcd);
        assertFalse(_moat.feeExemptCallers(account), "Should not be exempt initially");

        vm.prank(_owner);
        vm.expectEmit(true, false, false, true);
        emit Moat.FeeExemptionUpdated(account, true);
        _moat.setFeeExempt(account, true);
        assertTrue(_moat.feeExemptCallers(account), "Should be exempt");

        vm.prank(_owner);
        vm.expectEmit(true, false, false, true);
        emit Moat.FeeExemptionUpdated(account, false);
        _moat.setFeeExempt(account, false);
        assertFalse(_moat.feeExemptCallers(account), "Exemption should be revoked");
    }

    function testSetFeeExempt_Revert_NotOwner() external {
        vm.prank(_user);
        vm.expectRevert(bytes("caller is not the owner"));
        _moat.setFeeExempt(address(0xabcd), true);
    }

    function testSetFeeExempt_Revert_ZeroAddress() external {
        vm.prank(_owner);
        vm.expectRevert(Moat.ErrorZeroAddress.selector);
        _moat.setFeeExempt(address(0), true);
    }

    function testWithdrawToL1_FeeExempt_NoBaseFee() external {
        vm.prank(_owner);
        _moat.setFeeExempt(_user, true);

        address targetL1 = address(0x1111);
        uint256 amountAligned = 0.5 ether;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.expectEmit(true, true, false, true);
        emit Moat.WithdrawalQueued(_user, targetL1, amountAligned, 0);

        vm.prank(_user);
        _moat.withdrawToL1{value: amountAligned}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Full amount should be withdrawn");
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore, "No fee should be collected");
    }

    function testWithdrawToL1_FeeExempt_DustStillFloored() external {
        vm.prank(_owner);
        _moat.setFeeExempt(_user, true);

        address targetL1 = address(0x1111);
        uint256 amountAligned = 0.5 ether;
        uint256 dust = 42;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.prank(_user);
        _moat.withdrawToL1{value: amountAligned + dust}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Amount should be floored even when exempt");
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + dust, "Dust should still go to the fee recipient");
    }

    function testWithdrawToL1_FeeExempt_UnexemptRestoresFee() external {
        vm.startPrank(_owner);
        _moat.setFeeExempt(_user, true);
        _moat.setFeeExempt(_user, false);
        vm.stopPrank();

        address targetL1 = address(0x1111);
        uint256 fee = _moat.withdrawalFee();
        uint256 amountAligned = 0.5 ether;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.prank(_user);
        _moat.withdrawToL1{value: amountAligned + fee}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Amount mismatch");
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + fee, "Base fee should be charged again");
    }

    function testWithdrawToL1_FeeExempt_SucceedsWhenFeeExceedsValue() external {
        // Guards against the fee-coverage check accidentally using the global
        // withdrawalFee instead of the effective (exempt) fee.
        vm.startPrank(_owner);
        _moat.setWithdrawalFee(10 ether);
        _moat.setFeeExempt(_user, true);
        vm.stopPrank();

        address targetL1 = address(0x1111);
        uint256 amountAligned = 0.5 ether; // well below the 10 ether base fee

        vm.prank(_user);
        _moat.withdrawToL1{value: amountAligned}(targetL1);

        assertEq(_mockMessenger.lastValue(), amountAligned, "Exempt withdrawal should succeed in full");
    }

    // --- Tests: Configuration Hardening --- //

    function testConstructor_Revert_EqualPrefixes() external {
        vm.expectRevert(Moat.ErrorEqualPrefixes.selector);
        new Moat(bytes1(0x1e), bytes1(0x1e));
    }

    function testWithdrawToL1_Revert_FeeDueButNoRecipient() external {
        // Fresh Moat with no feeRecipient configured. Any withdrawal that owes a fee
        // (here: flooring dust with a zero base fee) must fail closed instead of
        // stranding the fee in the contract.
        Moat freshMoat = new Moat(_P2PKH_PREFIX, _P2SH_PREFIX);
        freshMoat.initialize(_owner);
        vm.prank(_owner);
        freshMoat.updateMessenger(address(_mockMessenger));

        vm.prank(_user);
        vm.expectRevert(Moat.ErrorFeeTransferFailed.selector);
        freshMoat.withdrawToL1{value: 0.5 ether + 42}(address(0x1111));
    }

    function testFeeExemptCallersStorageSlot() external {
        // Upgrade-safety regression: feeExemptCallers must stay appended at slot 57
        // (the first slot after depositFee). A layout shift would silently corrupt
        // proxy state on upgrade.
        address account = address(0xabcd);
        bytes32 slot = keccak256(abi.encode(account, uint256(57)));

        assertFalse(_moat.feeExemptCallers(account), "Should not be exempt initially");

        vm.store(address(_moat), slot, bytes32(uint256(1)));
        assertTrue(_moat.feeExemptCallers(account), "Getter must read mapping at slot 57");

        vm.store(address(_moat), slot, bytes32(uint256(0)));
        assertFalse(_moat.feeExemptCallers(account), "Getter must reflect cleared slot");
    }

    // --- Tests: Base58Check Decoding (DogeAddressLib) --- //

    // Test vector: Mainnet P2PKH address
    // Prefix 0x1e, payload: 0x89abcdef89abcdef89abcdef89abcdef89abcdef
    function testDecode_ValidMainnetP2PKH() external pure {
        // This is a valid mainnet P2PKH address (prefix 0x1e)
        // Address: DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz
        // Payload: 0x89abcdef89abcdef89abcdef89abcdef89abcdef
        string memory addr = "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz";
        (bytes1 prefix, bytes20 payload) = DogeAddressLib.decode(addr);

        assertEq(prefix, bytes1(0x1e), "Prefix should be 0x1e (mainnet P2PKH)");
        assertEq(payload, bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF), "Payload mismatch");
    }

    // Test vector: Mainnet P2SH address
    // Prefix 0x16
    function testDecode_ValidMainnetP2SH() external pure {
        // This is a valid mainnet P2SH address (prefix 0x16)
        // Address: 9rYHbG7NUbMEX7jEGCXeHVZ7RiowPFZPPN
        // Payload: 0x0123456789012345678901234567890123456789
        string memory addr = "9rYHbG7NUbMEX7jEGCXeHVZ7RiowPFZPPN";
        (bytes1 prefix, bytes20 payload) = DogeAddressLib.decode(addr);

        assertEq(prefix, bytes1(0x16), "Prefix should be 0x16 (mainnet P2SH)");
        assertEq(payload, bytes20(0x0123456789012345678901234567890123456789), "Payload mismatch");
    }

    function testDecode_ValidTestnetP2PKH() external pure {
        // Valid testnet P2PKH address (prefix 0x71)
        // Payload: 0x89abcdef89abcdef89abcdef89abcdef89abcdef
        string memory addr = "ngk6ejVecZ9Y7aLGQhKUL7JPBUVVdeoBmd";
        (bytes1 prefix, bytes20 payload) = DogeAddressLib.decode(addr);

        assertEq(prefix, bytes1(0x71), "Prefix should be 0x71 (testnet P2PKH)");
        assertEq(payload, bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF), "Payload mismatch");
    }

    function testDecode_ValidTestnetP2SH_35Chars() external pure {
        // Valid testnet/regtest P2SH address (prefix 0xc4). The 0xc4 version byte
        // pushes the Base58 encoding to 35 characters — the maximum length must
        // stay 35 to keep these canonical addresses accepted.
        string memory addr = "2N5oANkEZYXcFzYuTSWxvaWtgRLsngz5GBG";
        assertEq(bytes(addr).length, 35, "Test vector must be 35 chars");
        (bytes1 prefix, bytes20 payload) = DogeAddressLib.decode(addr);

        assertEq(prefix, bytes1(0xc4), "Prefix should be 0xc4 (testnet P2SH)");
        assertEq(payload, bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF), "Payload mismatch");
    }

    function testDecode_LeadingOneEncodesLeadingZeroByte() external pure {
        // Version byte 0x00 (Bitcoin-style) produces a leading '1' character,
        // exercising the leading-zero handling in the decoder.
        string memory addr = "1DYwPTp6PAnXhbaUeHgTXwYV4UNuN85ZJw";
        (bytes1 prefix, bytes20 payload) = DogeAddressLib.decode(addr);

        assertEq(prefix, bytes1(0x00), "Prefix should be 0x00");
        assertEq(payload, bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF), "Payload mismatch");
    }

    function testDecode_InteriorZeroPayload() external pure {
        // Payload that is almost all zero bytes (mainnet P2PKH prefix) — exercises
        // the used-length tracking in the big-number conversion.
        string memory addr = "D596YFweJQuHY1BbjazZYmAbt8jJXaDhSF";
        (bytes1 prefix, bytes20 payload) = DogeAddressLib.decode(addr);

        assertEq(prefix, bytes1(0x1e), "Prefix should be 0x1e (mainnet P2PKH)");
        assertEq(payload, bytes20(0x0000000000000000000000000000000000000001), "Payload mismatch");
    }

    function testDecode_Revert_OverflowNonCanonical() external {
        // 35-char string whose Base58 integer is the canonical
        // DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz value plus 2^200 — before the carry
        // guard this silently truncated to the same 25 bytes (valid checksum) and
        // was accepted as a non-canonical alias.
        string memory addr = "2zJDSzX4VSmK7bZTFeGwcDoPV4k4gftvWxG";

        vm.expectRevert(abi.encodeWithSelector(DogeAddressLib.ErrorInvalidDecodedLength.selector, 25, 26));
        _libWrapper.decode(addr);
    }

    function testDecode_Revert_InvalidBase58Character() external {
        // Address containing 'O' (invalid Base58 character)
        string memory addr = "DOgecoinIsGreat12345678901234";

        vm.expectRevert(abi.encodeWithSelector(DogeAddressLib.ErrorInvalidBase58Character.selector, uint8(0x4F))); // 'O' = 0x4F
        _libWrapper.decode(addr);
    }

    function testDecode_Revert_InvalidBase58Character_Zero() external {
        // Address containing '0' (invalid Base58 character)
        string memory addr = "D0gecoinIsGreat12345678901234";

        vm.expectRevert(abi.encodeWithSelector(DogeAddressLib.ErrorInvalidBase58Character.selector, uint8(0x30))); // '0' = 0x30
        _libWrapper.decode(addr);
    }

    function testDecode_Revert_InvalidBase58Character_LowercaseL() external {
        // Address containing 'l' (invalid Base58 character)
        string memory addr = "Dlgecoin12345678901234567890123";

        vm.expectRevert(abi.encodeWithSelector(DogeAddressLib.ErrorInvalidBase58Character.selector, uint8(0x6C))); // 'l' = 0x6C
        _libWrapper.decode(addr);
    }

    function testDecode_Revert_TooShort() external {
        string memory addr = "DShortAddr";

        vm.expectRevert(
            abi.encodeWithSelector(
                DogeAddressLib.ErrorInvalidInputLength.selector,
                uint256(25),
                uint256(35),
                uint256(10)
            )
        );
        _libWrapper.decode(addr);
    }

    function testDecode_Revert_TooLong() external {
        string memory addr = "DThisAddressIsWayTooLongToBeAValidDogeAddress12789";

        vm.expectRevert(
            abi.encodeWithSelector(
                DogeAddressLib.ErrorInvalidInputLength.selector,
                uint256(25),
                uint256(35),
                uint256(50)
            )
        );
        _libWrapper.decode(addr);
    }

    function testDecode_Revert_BadChecksum() external {
        // Valid format but wrong checksum (last char changed)
        string memory addr = "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFy1"; // Changed last char

        vm.expectRevert(DogeAddressLib.ErrorInvalidChecksum.selector);
        _libWrapper.decode(addr);
    }

    // --- Tests: decodeChecked Prefix Validation --- //

    function testDecodeChecked_AcceptMainnetP2PKH() external pure {
        string memory addr = "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz";

        (bool isP2SH, bytes20 payload) = DogeAddressLib.decodeChecked(
            addr,
            bytes1(0x1e), // mainnet P2PKH
            bytes1(0x16) // mainnet P2SH
        );

        assertEq(isP2SH, false, "Should be P2PKH");
        assertEq(payload, bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF), "Payload mismatch");
    }

    function testDecodeChecked_AcceptMainnetP2SH() external pure {
        string memory addr = "9rYHbG7NUbMEX7jEGCXeHVZ7RiowPFZPPN";

        (bool isP2SH, bytes20 payload) = DogeAddressLib.decodeChecked(
            addr,
            bytes1(0x1e), // mainnet P2PKH
            bytes1(0x16) // mainnet P2SH
        );

        assertEq(isP2SH, true, "Should be P2SH");
        assertEq(payload, bytes20(0x0123456789012345678901234567890123456789), "Payload mismatch");
    }

    function testDecodeChecked_Revert_WrongNetworkPrefix() external {
        // Mainnet P2PKH address but configured for testnet prefixes
        string memory addr = "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz";

        vm.expectRevert(abi.encodeWithSelector(DogeAddressLib.ErrorUnrecognizedPrefix.selector, bytes1(0x1e)));
        _libWrapper.decodeChecked(
            addr,
            bytes1(0x71), // testnet P2PKH
            bytes1(0xc4) // testnet P2SH
        );
    }

    // --- Tests: withdrawToDogeAddress Route Selection --- //

    function testWithdrawToDogeAddress_RoutesToP2PKH() external {
        // Use a mainnet P2PKH address
        string memory dogeAddr = "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz";
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        vm.prank(_user);
        _moat.withdrawToDogeAddress{value: totalValue}(dogeAddr);

        // Verify envelope has P2PKH flag (0)
        assertEq(_mockMessenger.lastMessage().length, 2, "Envelope length should be 2");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Envelope version should be 1");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(0)), "Envelope flags should be 0 (P2PKH)");

        // Verify target matches the decoded payload
        assertEq(
            _mockMessenger.lastTarget(),
            address(bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF)),
            "Target mismatch"
        );
    }

    function testWithdrawToDogeAddress_RoutesToP2SH() external {
        // Use a mainnet P2SH address
        string memory dogeAddr = "9rYHbG7NUbMEX7jEGCXeHVZ7RiowPFZPPN";
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        vm.prank(_user);
        _moat.withdrawToDogeAddress{value: totalValue}(dogeAddr);

        // Verify envelope has P2SH flag (1)
        assertEq(_mockMessenger.lastMessage().length, 2, "Envelope length should be 2");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Envelope version should be 1");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(1)), "Envelope flags should be 1 (P2SH)");

        // Verify target matches the decoded payload
        assertEq(
            _mockMessenger.lastTarget(),
            address(bytes20(0x0123456789012345678901234567890123456789)),
            "Target mismatch"
        );
    }

    function testWithdrawToDogeAddress_FeeLogic() external {
        string memory dogeAddr = "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz";
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        vm.prank(_user);
        _moat.withdrawToDogeAddress{value: totalValue}(dogeAddr);

        // Verify fee was transferred
        uint256 feeRecipBalanceAfter = _feeRecipient.balance;
        assertEq(feeRecipBalanceAfter, feeRecipBalanceBefore + fee, "Fee recipient balance mismatch");

        // Verify amount sent to messenger
        assertEq(_mockMessenger.lastValue(), amountToSend, "Value sent to messenger mismatch");
    }

    function testWithdrawToDogeAddress_Revert_InvalidAddress() external {
        string memory badAddr = "DInvalidAddressWithBadChecksum1234";
        uint256 amountToSend = 0.5 ether;
        uint256 fee = _moat.withdrawalFee();
        uint256 totalValue = amountToSend + fee;

        vm.prank(_user);
        vm.expectRevert(); // Will revert with checksum or length error
        _moat.withdrawToDogeAddress{value: totalValue}(badAddr);
    }

    function testWithdrawToDogeAddress_Revert_WrongNetworkPrefix() external {
        // Valid testnet P2PKH address (prefix 0x71, payload 0x89ab..ef) on a Moat
        // configured with mainnet prefixes (0x1e, 0x16).
        string memory testnetAddr = "ngk6ejVecZ9Y7aLGQhKUL7JPBUVVdeoBmd";
        uint256 totalValue = 0.5 ether + _moat.withdrawalFee();

        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(DogeAddressLib.ErrorUnrecognizedPrefix.selector, bytes1(0x71)));
        _moat.withdrawToDogeAddress{value: totalValue}(testnetAddr);
    }

}
