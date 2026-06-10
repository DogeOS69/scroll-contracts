// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {IMoat} from "./IMoat.sol";

/**
 * @title FeeVaultMoatAdapter
 * @notice Routes L2TxFeeVault withdrawals through the Moat so they become standard
 * Moat withdrawals (sent from the Moat, carrying the v1 envelope, with the amount
 * floored to Dogecoin's 8-decimal precision).
 * @dev The fee vault's owner points `vault.messenger` at this contract. The vault
 * calls the 4-arg `sendMessage` (the only entry point it uses), and this adapter
 * forwards the value to `Moat.withdrawToP2PKH`, reinterpreting the vault's
 * `recipient` as the Dogecoin P2PKH hash160 payload. The Moat owner is expected to
 * mark this adapter fee-exempt via `Moat.setFeeExempt` so the protocol does not pay
 * its own withdrawal fee.
 */
contract FeeVaultMoatAdapter {
    // --- Errors --- //
    error ErrorZeroAddress();
    error ErrorSenderNotFeeVault(address sender, address expected);
    error ErrorValueMismatch(uint256 value, uint256 msgValue);

    // --- Immutables --- //

    /// @notice The L2TxFeeVault allowed to withdraw through this adapter.
    address public immutable FEE_VAULT;

    /// @notice The Moat contract withdrawals are routed through.
    address public immutable MOAT;

    /**
     * @notice Constructor
     * @param _feeVault The L2TxFeeVault address.
     * @param _moat The Moat (proxy) address.
     */
    constructor(address _feeVault, address _moat) {
        if (_feeVault == address(0) || _moat == address(0)) {
            revert ErrorZeroAddress();
        }
        FEE_VAULT = _feeVault;
        MOAT = _moat;
    }

    /**
     * @notice Forwards a fee vault withdrawal into the Moat as a P2PKH withdrawal.
     * @dev Matches the `IL2ScrollMessenger.sendMessage` call made by
     * `L2TxFeeVault.withdraw`. Only callable by the fee vault.
     * @param _to The vault's recipient, interpreted as a Dogecoin P2PKH hash160 payload.
     * @param _value The withdrawal amount; must equal msg.value.
     */
    function sendMessage(
        address _to,
        uint256 _value,
        bytes calldata, /* _message (unused, vault sends empty bytes) */
        uint256 /* _gasLimit (unused) */
    ) external payable {
        if (msg.sender != FEE_VAULT) {
            revert ErrorSenderNotFeeVault(msg.sender, FEE_VAULT);
        }
        if (_value != msg.value) {
            revert ErrorValueMismatch(_value, msg.value);
        }
        IMoat(MOAT).withdrawToP2PKH{value: msg.value}(_to);
    }
}
