// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {OwnableBase} from "../libraries/common/OwnableBase.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IL2ScrollMessenger} from "../L2/IL2ScrollMessenger.sol";
import {IBasculeVerifier} from "./IBasculeVerifier.sol";

/**
 * @title Moat
 * @notice Handles verified L1->L2 message execution and L2->L1 withdrawals via the L2DogeOsMessenger.
 */
contract Moat is OwnableBase, ReentrancyGuardUpgradeable {
    // --- Errors --- //
    error ErrorZeroAddress();
    error ErrorFeeNotCovered();
    error ErrorBelowMinimumWithdrawal();
    error ErrorOnlyMessenger(address sender, address expected);
    error ErrorUnprovenL1Message();
    error ErrorTargetRevert();
    error ErrorInvalidDataLength(uint256 length);

    // --- Events --- //
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event DepositFeeUpdated(uint256 oldFee, uint256 newFee);
    event MinWithdrawalUpdated(uint256 oldMin, uint256 newMin);
    event FeeRecipientUpdated(address indexed oldRecip, address indexed newRecip);
    event BasculeVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event WithdrawalQueued(address indexed sender, address indexed target, uint256 amount, uint256 fee);
    event MessengerUpdated(address indexed oldMessenger, address indexed newMessenger);

    event DepositReceived(address indexed sender, address indexed target, uint256 amount, uint256 fee);

    // --- State Variables --- //

    /// @notice The L2 messenger contract used for L2->L1 communication.
    address public messenger;

    /// @notice The Bascule verifier contract for checking L1 message validity.
    address public basculeVerifier;

    /// @notice The fee required for L2->L1 withdrawals.
    uint256 public withdrawalFee;

    /// @notice The minimum amount (after fee) allowed for withdrawals.
    uint256 public minWithdrawalAmount;

    /// @notice The recipient address for withdrawal and deposit fees.
    address public feeRecipient;

    /// @notice The fee required for L1->L2 deposits.
    uint256 public depositFee;


    // --- Constructor --- //

    /**
     * @notice Constructor
     */
    constructor() /* address _initialOwner */
    {
        // Messenger address must be set separately via updateMessenger()
        // _transferOwnership(_initialOwner); // Initialize ownership
    }

    /**
     * @notice initialize the owner
     * @param _initialOwner The initial owner of the Moat contract.
     */
    function initialize(address _initialOwner) external initializer {
        __ReentrancyGuard_init();
        _transferOwnership(_initialOwner);
    }

    // --- Setters (Owner Restricted) --- //

    /**
     * @notice Update the L2 messenger contract address.
     * @dev Can only be called by the owner. Emits a {MessengerUpdated} event.
     * @param _newMessenger The new L2 messenger address.
     */
    function updateMessenger(address _newMessenger) external onlyOwner {
        if (_newMessenger == address(0)) {
            revert ErrorZeroAddress();
        }
        address oldMessenger = messenger;
        messenger = _newMessenger;
        emit MessengerUpdated(oldMessenger, _newMessenger);
    }

    /**
     * @notice Update the withdrawal fee.
     * @dev Can only be called by the owner. Emits a {WithdrawalFeeUpdated} event.
     * @param _newFee The new withdrawal fee.
     */
    function setWithdrawalFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = withdrawalFee;
        withdrawalFee = _newFee;
        emit WithdrawalFeeUpdated(oldFee, _newFee);
    }

    /**
     * @notice Update the deposit fee.
     * @dev Can only be called by the owner. Emits a {DepositFeeUpdated} event.
     * @param _newFee The new deposit fee.
     */
    function setDepositFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = depositFee;
        depositFee = _newFee;
        emit DepositFeeUpdated(oldFee, _newFee);
    }


    /**
     * @notice Update the minimum withdrawal amount (after fee).
     * @dev Can only be called by the owner. Emits a {MinWithdrawalUpdated} event.
     * @param _newMin The new minimum withdrawal amount.
     */
    function setMinWithdrawal(uint256 _newMin) external onlyOwner {
        uint256 oldMin = minWithdrawalAmount;
        minWithdrawalAmount = _newMin;
        emit MinWithdrawalUpdated(oldMin, _newMin);
    }

    /**
     * @notice Update the withdrawal fee recipient address.
     * @dev Can only be called by the owner. Emits a {FeeRecipientUpdated} event.
     * @param _newRecip The new fee recipient address.
     */
    function setFeeRecipient(address _newRecip) external onlyOwner {
        if (_newRecip == address(0)) {
            revert ErrorZeroAddress();
        }
        address oldRecip = feeRecipient;
        feeRecipient = _newRecip;
        emit FeeRecipientUpdated(oldRecip, _newRecip);
    }

    /**
     * @notice Update the Bascule verifier contract address.
     * @dev Can only be called by the owner. Emits a {BasculeVerifierUpdated} event.
     * @param _newVerifier The new Bascule verifier address.
     */
    function setBascule(address _newVerifier) external onlyOwner {
        // We allow setting verifier to address(0) to disable verification if needed.
        address oldVerifier = basculeVerifier;
        basculeVerifier = _newVerifier;
        emit BasculeVerifierUpdated(oldVerifier, _newVerifier);
    }

    // --- Core Logic --- //

    /**
     * @notice Handles execution of a verified L1->L2 message.
     * @dev Must be called by the designated L2 messenger. Requires message verification via Bascule.
     * Relays the call (and value) to the target address.
     * @param _target The target receipient address on L2.
     * @param _depositID The L1 deposit ID (expected to be bytes32).
     */
    function handleL1Message(address _target, bytes32 _depositID) external payable nonReentrant {
        // Check 1: Caller must be the messenger this Moat is configured for.
        address _messenger = messenger;
        if (_messenger == address(0)) {
            revert ErrorZeroAddress();
        }
        if (msg.sender != _messenger) {
            revert ErrorOnlyMessenger(msg.sender, _messenger);
        }

        // Check 2: Message must be verified by the Bascule verifier (if configured).
        address _verifier = basculeVerifier;
        if (_verifier != address(0)) {
            uint256 withdrawalAmount = msg.value;
            // validateWithdrawal is expected to revert on failure
            IBasculeVerifier(_verifier).validateWithdrawal(_target, _depositID, withdrawalAmount);
        }

        // Apply deposit fee logic (cache state variables for gas optimization)
        uint256 _depositFee = depositFee;
        address _feeRecipient = feeRecipient;
        uint256 feeCollected = 0;
        uint256 amountToTarget = msg.value;

        if (_depositFee > 0 && _feeRecipient != address(0)) {
            if (msg.value <= _depositFee) {
                // All funds go to fee recipient, no target call
                (bool success, ) = _feeRecipient.call{value: msg.value}("");
                feeCollected = msg.value;
                amountToTarget = 0;
                emit DepositReceived(msg.sender, _target, msg.value, feeCollected);
                return; // Early return, skip target call
            } else {
                // Deduct fee and continue to target
                amountToTarget = msg.value - _depositFee;
                feeCollected = _depositFee;
                
                // Transfer fee to recipient
                (bool success, ) = _feeRecipient.call{value: _depositFee}("");
            }
        }

        // Emit DepositReceived event with fee information
        emit DepositReceived(msg.sender, _target, msg.value, feeCollected);

        // Continue with target call if there's amount remaining
        if (amountToTarget > 0) {
            (bool ok, ) = _target.call{value: amountToTarget}(bytes(""));
            if (!ok) {
                revert ErrorTargetRevert();
            }
        }
    }

    /**
     * @notice Initiates a withdrawal from L2 to L1 via the L2 messenger.
     * @dev Requires withdrawal fee and minimum amount checks.
     * @param _target The recipient address on L1.
     */
    function withdrawToL1(address _target) external payable nonReentrant {
        uint256 fee = withdrawalFee;
        uint256 minAmount = minWithdrawalAmount;

        // Check 1: Fee must be covered by msg.value.
        if (msg.value <= fee) {
            revert ErrorFeeNotCovered();
        }

        uint256 amountAfterFee = msg.value - fee;

        // Check 2: Amount after fee must meet the minimum.
        if (amountAfterFee < minAmount) {
            revert ErrorBelowMinimumWithdrawal();
        }

        // Transfer fee to the recipient.
        address payable feeRecip = payable(feeRecipient);
        if (feeRecip != address(0) && fee > 0) {
            // Use call to avoid potential gas stipend issues with transfer()
            (bool success, ) = feeRecip.call{value: fee}("");
            // If fee transfer fails, it shouldn't block the withdrawal, maybe just emit an event?
            // For now, we'll proceed regardless of fee transfer success.
            // require(success, "Fee transfer failed"); // Uncomment if fee transfer failure should revert.
        }

        // Send the message via the L2 messenger.
        IL2ScrollMessenger(messenger).sendMessage{value: amountAfterFee}(
            _target,
            amountAfterFee, // Send the value after fee deduction
            bytes(""),
            0
        );

        // Emit event.
        emit WithdrawalQueued(msg.sender, _target, amountAfterFee, fee);
    }
}
