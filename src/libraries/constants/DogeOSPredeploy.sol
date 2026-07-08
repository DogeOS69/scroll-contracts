// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

library DogeOSPredeploy {
    /// @notice Canonical address of the native DOGE ERC-20-duality predeploy.
    /// @dev Uses a DogeOS vanity slot in the 0x5300 predeploy namespace while
    ///      leaving the inherited low Scroll-system range open for compatibility.
    address internal constant L2_NATIVE_DOGE_TOKEN = 0x530000000000000000000000000000000000d09e;

    /// @notice Restricted native-balance transfer precompile.
    /// @dev Required behavior:
    ///      - callable only by L2_NATIVE_DOGE_TOKEN
    ///      - input exactly abi.encode(address from, address to, uint256 amount)
    ///      - debits native balance[from], credits native balance[to]
    ///      - reverts if balance[from] < amount
    ///      - executes no recipient code
    ///      - returns exactly abi.encode(uint256(1)) on success
    address internal constant NATIVE_TRANSFER_PRECOMPILE = 0x00000000000000000000000000000000000000fd;
}
