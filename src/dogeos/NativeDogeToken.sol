// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {INativeDogeToken} from "./INativeDogeToken.sol";
import {DogeOSPredeploy} from "../libraries/constants/DogeOSPredeploy.sol";

/// @title NativeDogeToken
/// @notice Celo-style ERC-20 surface for DogeOS native DOGE.
/// @dev Native balance is the source of truth:
///      - balanceOf(a) == a.balance.
///      - No storage balances.
///      - Allowances are storage.
///      - transfer/transferFrom call a restricted native-transfer precompile.
///      - Recipient code is not executed.
contract NativeDogeToken is INativeDogeToken {
    error ErrorTotalSupplyUninitialized();
    error ErrorTransferToZeroAddress();
    error ErrorTransferFromZeroAddress();
    error ErrorApproveToZeroAddress();
    error ErrorInsufficientBalance(address from, uint256 balance, uint256 amount);
    error ErrorInsufficientAllowance(address owner, address spender, uint256 allowance, uint256 amount);
    error ErrorNativeTransferFailed(address from, address to, uint256 amount);

    /// @dev Slot 0. Set once at genesis by copying constructor-initialized storage.
    ///      There is deliberately no setter.
    uint256 private _totalSupply;

    /// @dev Slot 1. Allowances are the only mutable token-accounting storage.
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @notice Constructor is used by normal deployments and by genesis scripts.
    /// @dev When runtime code is etched into the canonical predeploy, the genesis
    ///      script must also copy slot 0 from this temporary deployment.
    constructor(uint256 totalSupply_) {
        if (totalSupply_ == 0) {
            revert ErrorTotalSupplyUninitialized();
        }

        _totalSupply = totalSupply_;
    }

    function name() external pure returns (string memory) {
        return "Dogecoin";
    }

    function symbol() external pure returns (string memory) {
        return "DOGE";
    }

    /// @notice Native L2 DOGE uses EVM wei semantics.
    /// @dev L1 Dogecoin's 8-decimal satoshi unit is a bridge-boundary concern.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        uint256 supply = _totalSupply;
        if (supply == 0) {
            revert ErrorTotalSupplyUninitialized();
        }

        return supply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return account.balance;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) {
            revert ErrorTransferToZeroAddress();
        }

        _nativeTransfer(msg.sender, to, amount);
        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) {
            revert ErrorApproveToZeroAddress();
        }

        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (from == address(0)) {
            revert ErrorTransferFromZeroAddress();
        }
        if (to == address(0)) {
            revert ErrorTransferToZeroAddress();
        }

        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert ErrorInsufficientAllowance(from, msg.sender, currentAllowance, amount);
            }

            _allowances[from][msg.sender] = currentAllowance - amount;
        }

        _nativeTransfer(from, to, amount);
        emit Transfer(from, to, amount);

        return true;
    }

    function _nativeTransfer(
        address from,
        address to,
        uint256 amount
    ) private {
        uint256 balance = from.balance;
        if (balance < amount) {
            revert ErrorInsufficientBalance(from, balance, amount);
        }

        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(from, to, amount)
        );

        if (!success || ret.length != 32 || abi.decode(ret, (uint256)) != 1) {
            revert ErrorNativeTransferFailed(from, to, amount);
        }
    }
}
