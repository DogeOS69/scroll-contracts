// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {DogeOSPredeploy} from "../../libraries/constants/DogeOSPredeploy.sol";

/**
 * @title NativeTransferPrecompileMock
 * @notice TEST-ONLY mock of the proposed restricted native-transfer precompile
 *         (DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE). Etched at that address in tests.
 * @dev Implements the exact contract documented on the constant: only-token caller,
 *      96-byte selector-less input abi.encode(from, to, amount), balance check, native
 *      move WITHOUT executing recipient code (vm.deal moves balances directly, matching
 *      the real precompile's no-hooks property), returns abi.encode(uint256(1)).
 *
 *      This mock plus the constant's NatSpec is the executable spec handed to the
 *      protocol team. Gas behavior is NOT faithful (cheatcodes) — Celo's reference
 *      price is 9,000 gas per transfer.
 */
contract NativeTransferPrecompileMock {
    /// @dev Foundry cheatcode VM.
    Vm private constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    error ErrorUnauthorizedCaller(address caller);
    error ErrorBadInputLength(uint256 length);
    error ErrorInsufficientBalance(address from, uint256 balance, uint256 amount);

    /// @dev Plain fallback + msg.data (rather than the parameterized
    ///      `fallback(bytes calldata) returns (bytes memory)` form, which
    ///      prettier-plugin-solidity mangles); the success word is returned via assembly.
    // solhint-disable-next-line payable-fallback
    fallback() external {
        if (msg.sender != DogeOSPredeploy.L2_DOGE_DUAL_TOKEN) {
            revert ErrorUnauthorizedCaller(msg.sender);
        }
        if (msg.data.length != 96) {
            revert ErrorBadInputLength(msg.data.length);
        }
        (address from, address to, uint256 amount) = abi.decode(msg.data, (address, address, uint256));

        uint256 fromBalance = from.balance;
        if (fromBalance < amount) {
            revert ErrorInsufficientBalance(from, fromBalance, amount);
        }
        // debit first so from == to nets to a no-op (DualityDogeShim._move pattern)
        VM.deal(from, fromBalance - amount);
        VM.deal(to, to.balance + amount);

        bytes memory ret = abi.encode(uint256(1));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}
