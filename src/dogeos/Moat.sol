// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {OwnableBase} from "../libraries/common/OwnableBase.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IL2ScrollMessenger} from "../L2/IL2ScrollMessenger.sol";
import {IBasculeVerifier} from "./IBasculeVerifier.sol";
import {DogeAddressLib} from "./DogeAddressLib.sol";

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
    error ErrorTargetRevert();
    error ErrorFeeTransferFailed();

    // --- Constants --- //

    /// @notice Message envelope version for P2PKH/P2SH withdrawals.
    uint8 private constant ENVELOPE_VERSION = 1;

    /// @notice Flag indicating P2SH address type in message envelope.
    uint8 private constant FLAG_P2SH = 0x01;

    // --- Immutables --- //

    /// @notice The P2PKH version byte for this network (0x1e mainnet, 0x71 testnet, 0x6f regtest).
    bytes1 public immutable P2PKH_PREFIX;

    /// @notice The P2SH version byte for this network (0x16 mainnet, 0xc4 testnet/regtest).
    bytes1 public immutable P2SH_PREFIX;

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
     * @notice Constructor sets immutable network prefixes.
     * @param _p2pkhPrefix The P2PKH version byte for this network.
     * @param _p2shPrefix The P2SH version byte for this network.
     */
    constructor(bytes1 _p2pkhPrefix, bytes1 _p2shPrefix) {
        P2PKH_PREFIX = _p2pkhPrefix;
        P2SH_PREFIX = _p2shPrefix;
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
                if (!success) revert ErrorFeeTransferFailed();
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
                if (!success) revert ErrorFeeTransferFailed();
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

    // --- Withdrawal Entry Points --- //

    /**
     * @notice (Deprecated) Initiates a P2PKH withdrawal; use withdrawToP2PKH instead.
     * @dev Now emits v1 envelope with flags=0 (P2PKH). Kept for backward compatibility.
     * @param _target The recipient address (hash160 payload).
     */
    function withdrawToL1(address _target) external payable nonReentrant {
        _processWithdrawal(_target, false);
    }

    /**
     * @notice Initiates a P2PKH withdrawal from L2 to L1 (Dogecoin).
     * @dev The target address is the hash160 of the public key.
     * @param _target The 20-byte hash160 payload as an address type.
     */
    function withdrawToP2PKH(address _target) external payable nonReentrant {
        _processWithdrawal(_target, false);
    }

    /**
     * @notice Initiates a P2SH withdrawal from L2 to L1 (Dogecoin).
     * @dev The target address is the hash160 of the redeem script.
     * @param _target The 20-byte script hash as an address type.
     */
    function withdrawToP2SH(address _target) external payable nonReentrant {
        _processWithdrawal(_target, true);
    }

    /**
     * @notice Withdraw to a Base58Check-encoded Dogecoin address.
     * @dev Decodes the address on-chain and routes to P2PKH or P2SH.
     * @param _dogeAddress The full Base58Check-encoded Dogecoin address.
     */
    function withdrawToDogeAddress(string calldata _dogeAddress) external payable nonReentrant {
        (bool isP2SH, bytes20 payload) = DogeAddressLib.decodeChecked(_dogeAddress, P2PKH_PREFIX, P2SH_PREFIX);
        _processWithdrawal(address(payload), isP2SH);
    }

    // --- Internal Functions --- //

    /**
     * @dev Encode the message envelope for withdrawal.
     * @param _isP2SH True for P2SH, false for P2PKH.
     * @return envelope The 2-byte message envelope (version, flags).
     */
    function _encodeEnvelope(bool _isP2SH) internal pure returns (bytes memory envelope) {
        envelope = new bytes(2);
        envelope[0] = bytes1(ENVELOPE_VERSION);
        envelope[1] = _isP2SH ? bytes1(FLAG_P2SH) : bytes1(0);
    }

    /**
     * @dev Internal function to process withdrawals with envelope encoding.
     * @param _target The 20-byte hash160/script-hash payload.
     * @param _isP2SH True for P2SH, false for P2PKH.
     */
    function _processWithdrawal(address _target, bool _isP2SH) internal {
        // Check 0: Messenger must be configured.
        address _messenger = messenger;
        if (_messenger == address(0)) {
            revert ErrorZeroAddress();
        }

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
            if (!success) revert ErrorFeeTransferFailed();
        }

        // Encode the message envelope.
        bytes memory envelope = _encodeEnvelope(_isP2SH);

        // Send the message via the L2 messenger.
        IL2ScrollMessenger(_messenger).sendMessage{value: amountAfterFee}(_target, amountAfterFee, envelope, 0);

        // Emit event.
        emit WithdrawalQueued(msg.sender, _target, amountAfterFee, fee);
    }
}
