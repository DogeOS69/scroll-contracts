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
    error ErrorUnprovenL1Message(); // Note: This seems unused in Moat.sol currently
    error ErrorTargetRevert();
    error ErrorInvalidDataLength(uint256 length);
    error Unauthorized(); // From OwnableBase inheritance

    // --- Events --- //

    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event MinWithdrawalUpdated(uint256 oldMin, uint256 newMin);
    event FeeRecipientUpdated(address indexed oldRecip, address indexed newRecip);
    event BasculeVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event WithdrawalQueued(address indexed sender, address indexed target, uint256 amount, uint256 fee);
    event MessengerUpdated(address indexed oldMessenger, address indexed newMessenger);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner); // From OwnableBase inheritance

    event DepositReceived(address indexed sender, address indexed target, uint256 amount);

    // --- Functions --- //

    // Getters for public state variables
    function messenger() external view returns (address);

    function basculeVerifier() external view returns (address);

    function withdrawalFee() external view returns (uint256);

    function minWithdrawalAmount() external view returns (uint256);

    function feeRecipient() external view returns (address);

    function owner() external view returns (address); // From OwnableBase inheritance

    // Setters
    function updateMessenger(address _newMessenger) external;

    function setFee(uint256 _newFee) external;

    function setMinWithdrawal(uint256 _newMin) external;

    function setFeeRecipient(address _newRecip) external;

    function setBascule(address _newVerifier) external;

    // Core Logic
    function handleL1Message(address _target, bytes32 _depositID) external payable;

    function withdrawToL1(address _target) external payable;

    // OwnableBase functions
    function transferOwnership(address newOwner) external;

    function renounceOwnership() external;
}
