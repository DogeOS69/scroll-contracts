// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title IBasculeVerifier
 * @notice Interface for a verifier contract that validates withdrawals based on deposit IDs.
 */
interface IBasculeVerifier {
    /**
     * @notice Validate a withdrawal against a known deposit.
     * @dev Reverts if the withdrawal is invalid (e.g., unknown depositID, already withdrawn).
     * Corresponds to IBascule.validateWithdrawal.
     * @param depositID Unique identifier of the deposit on another chain.
     * @param withdrawalAmount Amount of the withdrawal.
     */
    function validateWithdrawal(bytes32 depositID, uint256 withdrawalAmount) external;
} 