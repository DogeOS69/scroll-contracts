// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/// @title INativeDoge
/// @notice ERC-20-shaped interface for token duality on the native DOGE asset.
/// @dev Production semantics:
///      - balanceOf(a) == a.balance at all times.
///      - There are no storage balances and no deposit/withdraw wrapping flow.
///      - transfer/transferFrom move native balance without executing recipient
///        code, so receive()/fallback() hooks are not triggered.
///      - Allowances are ordinary contract storage.
///      - totalSupply is the configured native supply cap / genesis supply.
///
///      Moving another account's native balance cannot be implemented in pure
///      EVM. A production implementation must be a canonical predeploy backed by
///      protocol support, such as a restricted native-transfer precompile.
interface INativeDoge {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    /// @notice Configured native supply cap / genesis supply.
    function totalSupply() external view returns (uint256);

    /// @notice The native balance of `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Moves native DOGE from the caller to `to` without executing
    ///         recipient code.
    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Moves native DOGE from `from` to `to` using the caller's
    ///         allowance, without executing recipient code.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}
