// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title INativeDoge
 * @notice ERC-20-shaped interface for "token duality" on the native DOGE asset:
 *         a token contract whose balances ARE native account balances, following the
 *         Celo model (CELO/GoldToken), rather than a WETH-style wrapped token with
 *         deposit/withdraw and storage balances.
 *
 * @dev Production semantics (what an implementation must guarantee):
 *      - `balanceOf(a)` equals `a.balance` at all times; there are no storage balances.
 *      - `transfer`/`transferFrom` move NATIVE balance from `from` to `to` WITHOUT
 *        executing code on the recipient: no `receive()`/`fallback()` is triggered
 *        (Celo's transfer precompile behaves the same way). Contracts that rely on
 *        value-call hooks must not assume duality transfers trigger them.
 *      - Allowances are ordinary contract storage.
 *
 *      A real implementation CANNOT be written in pure EVM: moving another account's
 *      native balance requires protocol support. Enabling this on DogeOS needs:
 *        1. a native-transfer precompile in l2geth/revm (callable only by the duality
 *           token contract), with prover/stateless-verifier support;
 *        2. a predeploy token contract at a canonical DogeOSPredeploy address that
 *           calls that precompile;
 *        3. genesis integration for the predeploy.
 *      None of that exists yet - it is protocol work tracked separately. This
 *      interface and the cheatcode-backed `DualityDogeShim` (src/test/mocks/) exist
 *      so contracts can be developed and functionally tested against duality
 *      semantics today. Do NOT use the shim's gas numbers; cheatcodes distort them.
 */
interface INativeDoge {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    /// @notice Total native supply. Implementation-defined; the test shim returns 0.
    function totalSupply() external view returns (uint256);

    /// @notice The native balance of `account` (identical to `account.balance`).
    function balanceOf(address account) external view returns (uint256);

    /// @notice Moves `amount` of native DOGE from the caller to `to` without
    ///         executing recipient code.
    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Moves `amount` of native DOGE from `from` to `to` using the caller's
    ///         allowance, without executing recipient code.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}
