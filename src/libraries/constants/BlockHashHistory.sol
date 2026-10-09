// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

/// @notice Canonical EIP-2935 account, not a Solidity implementation or proxy.
/// @dev https://eips.ethereum.org/EIPS/eip-2935#deployment
/// The 9-byte constructor (60538060095f395ff3) is excluded from the runtime.
library BlockHashHistory {
    address internal constant ADDRESS = 0x0000F90827F1C53a10cb7A02335B175320002935;
    bytes internal constant RUNTIME_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";
}
