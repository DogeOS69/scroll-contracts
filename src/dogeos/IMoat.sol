// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title IMoat
 * @notice Interface for the DogeOS Moat contract.
 */
interface IMoat {
    // --- Errors --- //

    error ErrorZeroAddress();
    error ErrorFeeNotCovered();
    error ErrorBelowMinimumWithdrawal();
    error ErrorOnlyMessenger(address sender, address expected);
    error ErrorTargetRevert();
    error ErrorFeeTransferFailed();
    error ErrorInvalidMinWithdrawal();
    error ErrorEqualPrefixes();
    error ErrorFeeRecipientNotSet();
    error ErrorCallerNotPendingOwner();

    // --- Events --- //

    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event DepositFeeUpdated(uint256 oldFee, uint256 newFee);
    event MinWithdrawalUpdated(uint256 oldMin, uint256 newMin);
    event FeeRecipientUpdated(address indexed oldRecip, address indexed newRecip);
    /// @notice Emitted when a withdrawal to L1 is queued. `sender` is the account that called
    /// the Moat (the FeeVaultMoatAdapter for fee vault withdrawals). The messenger's
    /// `SentMessage` in the same transaction always has the Moat as its sender.
    event WithdrawalQueued(address indexed sender, address indexed target, uint256 amount, uint256 fee);
    event FeeExemptionUpdated(address indexed account, bool exempt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner); // From OwnableBase inheritance
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    event DepositReceived(address indexed sender, address indexed target, uint256 amount, uint256 fee);
    event FeesSwept(address indexed recipient, uint256 amount);

    // --- Functions --- //

    // Getters for public state variables
    function messenger() external view returns (address);

    function withdrawalFee() external view returns (uint256);

    function depositFee() external view returns (uint256);

    function minWithdrawalAmount() external view returns (uint256);

    function feeRecipient() external view returns (address);

    function feeExemptCallers(address _account) external view returns (bool);

    function owner() external view returns (address); // From OwnableBase inheritance

    function pendingOwner() external view returns (address);

    // Setters
    function setWithdrawalFee(uint256 _newFee) external;

    function setDepositFee(uint256 _newFee) external;

    function setMinWithdrawal(uint256 _newMin) external;

    function setFeeRecipient(address _newRecip) external;

    function setFeeExempt(address _account, bool _exempt) external;

    // Immutable/Constant Getters
    function P2PKH_PREFIX() external view returns (bytes1);

    function P2SH_PREFIX() external view returns (bytes1);

    function MESSENGER() external view returns (address);

    function SATOSHI_TO_WEI() external view returns (uint256);

    // Core Logic
    function handleL1Message(address _target, bytes32 _depositID) external payable;

    function withdrawToL1(address _target) external payable;

    function withdrawToP2PKH(address _target) external payable;

    function withdrawToP2SH(address _target) external payable;

    function withdrawToDogeAddress(string calldata _dogeAddress) external payable;

    function sweepFees() external returns (uint256 amount);

    // Ownership (two-step: transferOwnership nominates, acceptOwnership completes)
    function transferOwnership(address newOwner) external;

    function acceptOwnership() external;

    function renounceOwnership() external;
}
