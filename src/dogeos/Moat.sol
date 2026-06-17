// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {OwnableBase} from "../libraries/common/OwnableBase.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IL2ScrollMessenger} from "../L2/IL2ScrollMessenger.sol";
import {DogeAddressLib} from "./DogeAddressLib.sol";
import {WithdrawalEnvelope} from "./WithdrawalEnvelope.sol";

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
    error ErrorInvalidMinWithdrawal();
    error ErrorEqualPrefixes();

    // --- Constants --- //

    /// @notice One satoshi (the smallest Dogecoin unit, 10^-8 DOGE) expressed in wei.
    /// Withdrawal amounts are floored to a multiple of this so they are exactly
    /// representable as a Dogecoin UTXO output.
    uint256 public constant SATOSHI_TO_WEI = 1e10;

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
    event WithdrawalQueued(address indexed sender, address indexed target, uint256 amount, uint256 fee);
    event MessengerUpdated(address indexed oldMessenger, address indexed newMessenger);
    event FeeExemptionUpdated(address indexed account, bool exempt);

    event DepositReceived(address indexed sender, address indexed target, uint256 amount, uint256 fee);

    // --- State Variables --- //

    /// @notice The L2 messenger contract used for L2->L1 communication.
    address public messenger;

    /// @dev Deprecated storage slot kept to preserve proxy upgrade layout.
    address private _deprecatedVerifierSlot;

    /// @notice The fee required for L2->L1 withdrawals.
    uint256 public withdrawalFee;

    /// @notice The minimum amount (after fee) allowed for withdrawals.
    uint256 public minWithdrawalAmount;

    /// @notice The recipient address for withdrawal and deposit fees.
    address public feeRecipient;

    /// @notice The fee required for L1->L2 deposits.
    uint256 public depositFee;

    /// @notice Callers exempt from the base withdrawal fee (e.g. the fee vault adapter).
    /// Exempt callers still have their withdrawal amount floored to SATOSHI_TO_WEI.
    mapping(address => bool) public feeExemptCallers;

    // --- Constructor --- //

    /**
     * @notice Constructor sets immutable network prefixes.
     * @dev Equal prefixes would make decodeChecked classify every address as P2PKH,
     * silently producing the wrong script type for P2SH withdrawals.
     * @param _p2pkhPrefix The P2PKH version byte for this network.
     * @param _p2shPrefix The P2SH version byte for this network.
     */
    constructor(bytes1 _p2pkhPrefix, bytes1 _p2shPrefix) {
        if (_p2pkhPrefix == _p2shPrefix) {
            revert ErrorEqualPrefixes();
        }
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
     * Reverts with {ErrorInvalidMinWithdrawal} when `_newMin` is below 0.01 ether
     * (0.01 DOGE) — a protocol floor keeping outputs comfortably above typical
     * Dogecoin dust thresholds.
     * @param _newMin The new minimum withdrawal amount.
     */
    function setMinWithdrawal(uint256 _newMin) external onlyOwner {
        if (_newMin < 0.01 ether) {
            revert ErrorInvalidMinWithdrawal();
        }
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
     * @notice Grant or revoke an exemption from the base withdrawal fee.
     * @dev Can only be called by the owner. Emits a {FeeExemptionUpdated} event.
     * Intended for protocol callers (e.g. the fee vault adapter) whose withdrawals
     * should not pay the protocol's own fee. Flooring to SATOSHI_TO_WEI still applies.
     * @param _account The caller address to update.
     * @param _exempt True to exempt the caller from the withdrawal fee.
     */
    function setFeeExempt(address _account, bool _exempt) external onlyOwner {
        if (_account == address(0)) {
            revert ErrorZeroAddress();
        }
        feeExemptCallers[_account] = _exempt;
        emit FeeExemptionUpdated(_account, _exempt);
    }

    // --- Core Logic --- //

    /**
     * @notice Handles execution of a messenger-gated L1->L2 message.
     * @dev Must be called by the designated L2 messenger. Relays the call
     * (and value) to the target address.
     * @param _target The target recipient address on L2.
     */
    function handleL1Message(address _target) external payable nonReentrant {
        // Check 1: Caller must be the messenger this Moat is configured for.
        address _messenger = messenger;
        if (_messenger == address(0)) {
            revert ErrorZeroAddress();
        }
        if (msg.sender != _messenger) {
            revert ErrorOnlyMessenger(msg.sender, _messenger);
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
     * The amount after fee is floored to a satoshi multiple; the remainder joins the fee.
     * @param _target The recipient address (hash160 payload).
     */
    function withdrawToL1(address _target) external payable nonReentrant {
        _processWithdrawal(_target, false);
    }

    /**
     * @notice Initiates a P2PKH withdrawal from L2 to L1 (Dogecoin).
     * @dev The target address is the hash160 of the public key.
     * The amount after fee is floored to a satoshi multiple; the remainder joins the fee.
     * @param _target The 20-byte hash160 payload as an address type.
     */
    function withdrawToP2PKH(address _target) external payable nonReentrant {
        _processWithdrawal(_target, false);
    }

    /**
     * @notice Initiates a P2SH withdrawal from L2 to L1 (Dogecoin).
     * @dev The target address is the hash160 of the redeem script.
     * The amount after fee is floored to a satoshi multiple; the remainder joins the fee.
     * @param _target The 20-byte script hash as an address type.
     */
    function withdrawToP2SH(address _target) external payable nonReentrant {
        _processWithdrawal(_target, true);
    }

    /**
     * @notice Withdraw to a Base58Check-encoded Dogecoin address.
     * @dev Decodes the address on-chain and routes to P2PKH or P2SH.
     * The amount after fee is floored to a satoshi multiple; the remainder joins the fee.
     * @param _dogeAddress The full Base58Check-encoded Dogecoin address.
     */
    function withdrawToDogeAddress(string calldata _dogeAddress) external payable nonReentrant {
        (bool isP2SH, bytes20 payload) = DogeAddressLib.decodeChecked(_dogeAddress, P2PKH_PREFIX, P2SH_PREFIX);
        _processWithdrawal(address(payload), isP2SH);
    }

    // --- Internal Functions --- //

    /**
     * @dev Internal function to process withdrawals with envelope encoding.
     * The amount after fee is floored to a multiple of {SATOSHI_TO_WEI} so it is
     * exactly representable on Dogecoin (8 decimals); the sub-satoshi remainder
     * is added to the fee. Callers in {feeExemptCallers} pay no base fee.
     * Whenever any fee (including dust) is due, `feeRecipient` must be configured
     * or the withdrawal reverts — fees are never left in this contract.
     * @param _target The 20-byte hash160/script-hash payload.
     * @param _isP2SH True for P2SH, false for P2PKH.
     */
    function _processWithdrawal(address _target, bool _isP2SH) internal {
        // Check 0: Messenger must be configured.
        address _messenger = messenger;
        if (_messenger == address(0)) {
            revert ErrorZeroAddress();
        }

        // Effective fee: exempt callers (e.g. the fee vault adapter) pay no base fee.
        uint256 fee = feeExemptCallers[msg.sender] ? 0 : withdrawalFee;
        uint256 minAmount = minWithdrawalAmount;

        // Check 1: Fee must be covered by msg.value.
        if (msg.value <= fee) {
            revert ErrorFeeNotCovered();
        }

        uint256 amountAfterFee = msg.value - fee;

        // Floor the amount to a satoshi multiple; the dust joins the fee so that
        // amountAfterFee + fee == msg.value still holds.
        uint256 dust = amountAfterFee % SATOSHI_TO_WEI;
        if (dust > 0) {
            amountAfterFee -= dust;
            fee += dust;
        }

        // Check 2: The floored amount must be non-zero and meet the minimum.
        if (amountAfterFee == 0 || amountAfterFee < minAmount) {
            revert ErrorBelowMinimumWithdrawal();
        }

        // Transfer fee to the recipient. Fail closed when a fee (or dust) is due but
        // no recipient is configured — otherwise the value would be stranded in this
        // contract, which has no sweep path, while the event reports it as collected.
        if (fee > 0) {
            address payable feeRecip = payable(feeRecipient);
            if (feeRecip == address(0)) revert ErrorFeeTransferFailed();
            // Use call to avoid potential gas stipend issues with transfer()
            // slither-disable-next-line arbitrary-send-eth
            (bool success, ) = feeRecip.call{value: fee}("");
            if (!success) revert ErrorFeeTransferFailed();
        }

        // Encode the message envelope (shared with the messenger's validation, so the
        // producer and the enforcer cannot drift).
        bytes memory envelope = WithdrawalEnvelope.encode(_isP2SH);

        // Send the message via the L2 messenger.
        IL2ScrollMessenger(_messenger).sendMessage{value: amountAfterFee}(_target, amountAfterFee, envelope, 0);

        // Emit event.
        emit WithdrawalQueued(msg.sender, _target, amountAfterFee, fee);
    }
}
