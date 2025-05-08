// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import { IBasculeVerifier } from "./IBasculeVerifier.sol";

/**
 * @title BasculeMockVerifier
 * @notice A mock implementation of IBasculeVerifier that performs no checks,
 * except for a specific hardcoded deposit ID for testing purposes.
 * Used for testing or initial deployments where real verification is not yet integrated.
 */
contract BasculeMockVerifier is IBasculeVerifier {
    /**
     * @notice Custom error to indicate mock rejection for a specific deposit ID.
     */
    error ErrorMockRejection();

    /**
     * @notice The specific deposit ID that will cause validation to fail in this mock.
     */
    bytes32 public constant REJECT_DEPOSIT_ID = 0xbadca11000000000000000000000000000000000000000000000000000000000;

    /**
     * @notice Mock verification function.
     * @dev Reverts if `depositID` is `REJECT_DEPOSIT_ID` or `withdrawalAmount` is 0,
     *      otherwise allows any withdrawal.
     * @inheritdoc IBasculeVerifier
     */
    function validateWithdrawal(
        bytes32 depositID,
        uint256 withdrawalAmount
    ) external pure override {
        // Check if the deposit ID matches the hardcoded rejection ID or amount is zero.
        if (depositID == REJECT_DEPOSIT_ID || withdrawalAmount == 0) {
            revert ErrorMockRejection();
        }
        // Mock implementation: Otherwise, do nothing.
        return;
    }
} 