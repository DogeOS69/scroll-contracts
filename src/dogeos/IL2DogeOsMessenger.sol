// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import { IL2ScrollMessenger } from "../L2/IL2ScrollMessenger.sol";

/**
 * @title IL2DogeOsMessenger
 * @notice Interface for the custom L2 messenger for DogeOS.
 * Inherits the base IL2ScrollMessenger interface and adds DogeOS-specific elements.
 */
interface IL2DogeOsMessenger is IL2ScrollMessenger {
    // --- Errors --- //

    /**
     * @notice Reverts when relayMessage is called with a `_to` address that is not the configured MOAT address.
     * @param provided The provided `_to` address.
     * @param expected The expected MOAT address.
     */
    error ErrorNotMoatAddress(address provided, address expected);

    /**
     * @notice Reverts when sendMessage is called by an address other than the configured MOAT address.
     * @param sender The actual sender address.
     * @param expected The expected MOAT address.
     */
    error ErrorSenderNotMoat(address sender, address expected);

    /**
     * @notice Reverts during construction if the provided MOAT address is the zero address.
     */
    error ErrorZeroMoatAddress();

    // --- Functions --- //

    /**
     * @notice Returns the immutable address of the DogeOS Moat contract.
     * @return The address of the Moat contract.
     */
    function MOAT() external view returns (address);

    // Note: Inherits sendMessage and relayMessage from IL2ScrollMessenger.
}