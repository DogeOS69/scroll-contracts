// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import { IBasculeVerifier } from "./IBasculeVerifier.sol";

/**
 * @title BasculeMockVerifier
 * @notice A mock implementation of IBasculeVerifier that performs no checks.
 * Used for testing or initial deployments where real verification is not yet integrated.
 */
contract BasculeMockVerifier is IBasculeVerifier {
    /**
     * @notice Mock verification function.
     * @dev Does nothing, effectively allowing any withdrawal.
     * @inheritdoc IBasculeVerifier
     */
    function validateWithdrawal(
        bytes32, /* depositID */
        uint256 /* withdrawalAmount */
    ) external pure override {
        // Mock implementation: Do nothing.
        return;
    }
} 