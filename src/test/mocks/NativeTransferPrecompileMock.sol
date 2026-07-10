// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {DogeOSPredeploy} from "../../libraries/constants/DogeOSPredeploy.sol";

/// @notice TEST-ONLY mock for the native-transfer precompile.
/// @dev Uses vm.deal, so it cannot be used outside Foundry tests.
contract NativeTransferPrecompileMock {
    Vm private constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    error ErrorUnauthorizedCaller(address caller);
    error ErrorInvalidInputLength(uint256 length);
    error ErrorInsufficientBalance(address from, uint256 balance, uint256 amount);

    // prettier-ignore
    fallback(bytes calldata input) external returns (bytes memory) {
        if (msg.sender != DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN) {
            revert ErrorUnauthorizedCaller(msg.sender);
        }
        if (input.length != 96) {
            revert ErrorInvalidInputLength(input.length);
        }

        (address from, address to, uint256 amount) = abi.decode(input, (address, address, uint256));

        uint256 fromBalance = from.balance;
        if (fromBalance < amount) {
            revert ErrorInsufficientBalance(from, fromBalance, amount);
        }

        VM.deal(from, fromBalance - amount);
        VM.deal(to, to.balance + amount);

        return "";
    }
}
