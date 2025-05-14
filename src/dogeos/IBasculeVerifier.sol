// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title IBasculeVerifier
 * @notice Interface for a verifier contract that validates withdrawals based on deposit IDs.
 */
interface IBasculeVerifier {
    // --- Events --- //

    event WithdrawalValidated(address indexed recipient, bytes32 indexed depositID, uint256 withdrawalAmount);

    // --- Functions --- //

    /**
     * @notice Validate a withdrawal against a known deposit.
     * @dev Reverts if the withdrawal is invalid (e.g., unknown depositID, already withdrawn).
     * Corresponds to IBascule.validateWithdrawal.
     * @param _recipient The recipient address of the withdrawal.
     * @param _depositID Unique identifier of the deposit on another chain.
     * @param _withdrawalAmount Amount of the withdrawal.
     */
    function validateWithdrawal(
        address _recipient,
        bytes32 _depositID,
        uint256 _withdrawalAmount
    ) external;
}
