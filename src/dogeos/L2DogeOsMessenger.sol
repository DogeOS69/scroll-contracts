// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import { L2ScrollMessenger } from "../L2/L2ScrollMessenger.sol";
// Potentially add import for Moat contract here

/**
 * @title L2DogeOsMessenger
 * @notice A custom L2 messenger for DogeOS, inheriting from L2ScrollMessenger.
 * It modifies the standard behavior to interact with the DogeOS Moat contract.
 */
contract L2DogeOsMessenger is L2ScrollMessenger {
    // --- Errors --- //
    error ErrorNotMoatAddress(address provided, address expected);
    error ErrorSenderNotMoat(address sender, address expected);
    error ErrorZeroMoatAddress();

    // --- State Variables --- //

    /// @notice The immutable address of the DogeOS Moat contract.
    /// @dev Only messages directed to this address will be executed.
    address public immutable MOAT;
    address public immutable FEE_VAULT;

    // --- Constructor --- //

    /**
     * @notice Constructor
     * @param _counterpart The address of the L1 counterpart messenger.
     * @param _messageQueue The address of the L2 Message Queue predeploy.
     * @param _moat The address of the DogeOS Moat contract.
     * @param _feeVault The address of the L2TxFeeVault contract.
     */
    constructor(
        address _counterpart,
        address _messageQueue,
        address _moat,
        address _feeVault
    ) L2ScrollMessenger(_counterpart, _messageQueue) {
        if (_moat == address(0)) {
            revert ErrorZeroMoatAddress();
        }
        MOAT = _moat;
        FEE_VAULT = _feeVault;
    }

    // --- Overridden Internal Functions --- //

    /**
     * @notice Overrides the L1 -> L2 message execution logic.
     * Ensures that messages relayed via this messenger are only executed if targeting the MOAT address.
     * @param _from The L1 sender address.
     * @param _to The originally intended L2 recipient address.
     * @param _value The ETH value sent with the message.
     * @param _message The encoded calldata intended for the target (_to).
     * @param _xDomainCalldataHash The hash of the cross-domain message calldata.
     */
    function _executeMessage(
        address _from,
        address _to,
        uint256 _value,
        bytes memory _message,
        bytes32 _xDomainCalldataHash
    ) internal virtual override {
        // Only allow messages destined for the Moat address.
        if (_to != MOAT) {
            revert ErrorNotMoatAddress(_to, MOAT);
        }

        // If the message is for the Moat, proceed with original execution logic.
        super._executeMessage({ 
            _from: _from,
            _to: _to,
            _value: _value,
            _message: _message,
            _xDomainCalldataHash: _xDomainCalldataHash 
        });
    }

    /**
     * @notice Overrides the L2 -> L1 message sending logic.
     * Adds checks, potentially related to the Moat (e.g., onlyMoat modifier).
     * @param _to The L1 recipient address.
     * @param _value The ETH value to send with the message.
     * @param _message The message calldata.
     * @param _gasLimit The gas limit for L1 execution.
     */
    function _sendMessage(
        address _to,
        uint256 _value,
        bytes memory _message,
        uint256 _gasLimit
    ) internal virtual override {
        // Require that the caller is the MOAT contract or the fee vault.
        if (msg.sender != MOAT && msg.sender != FEE_VAULT) {
            revert ErrorSenderNotMoat(msg.sender, MOAT);
        }

        // Call the original logic
        super._sendMessage(_to, _value, _message, _gasLimit);
    }

}
