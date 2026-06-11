// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {INativeDoge} from "../../dogeos/INativeDoge.sol";

/**
 * @title DualityDogeShim
 * @notice TEST-ONLY functional shim for Celo-style token duality on native DOGE.
 * @dev Implements {INativeDoge} inside Foundry tests by moving native balances with
 *      the `vm.deal` cheatcode - the in-EVM stand-in for the native-transfer
 *      precompile a real implementation requires (see INativeDoge for the protocol
 *      work involved).
 *
 *      Faithful to production semantics:
 *      - `balanceOf` IS the native balance; there are no storage balances.
 *      - transfers do NOT execute recipient code (no receive()/fallback hooks),
 *        matching the precompile behavior.
 *      - allowances are ordinary storage; infinite allowance is not decremented.
 *
 *      NOT faithful: gas. Cheatcode calls have arbitrary gas behavior - never use
 *      this shim for gas measurements.
 *
 *      Lives under src/test/mocks/ so hardhat (which cannot resolve forge-std) never
 *      compiles it; it is also excluded from slither/coverage. It cannot work outside
 *      a Foundry test VM: the cheatcode address only answers there.
 */
contract DualityDogeShim is INativeDoge {
    /// @dev Foundry cheatcode VM (`address(uint160(uint256(keccak256("hevm cheat code"))))`).
    Vm private constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    error ErrorInsufficientBalance(address from, uint256 balance, uint256 amount);
    error ErrorInsufficientAllowance(address owner, address spender, uint256 allowance, uint256 amount);

    mapping(address => mapping(address => uint256)) private _allowances;

    function name() external pure returns (string memory) {
        return "Dogecoin";
    }

    function symbol() external pure returns (string memory) {
        return "DOGE";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @inheritdoc INativeDoge
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc INativeDoge
    function balanceOf(address account) external view returns (uint256) {
        return account.balance;
    }

    /// @inheritdoc INativeDoge
    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc INativeDoge
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc INativeDoge
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc INativeDoge
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) {
                revert ErrorInsufficientAllowance(from, msg.sender, allowed, amount);
            }
            _allowances[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    /// @dev Native balance move via cheatcode; order handles to == from correctly.
    function _move(
        address from,
        address to,
        uint256 amount
    ) private {
        uint256 fromBalance = from.balance;
        if (fromBalance < amount) {
            revert ErrorInsufficientBalance(from, fromBalance, amount);
        }
        VM.deal(from, fromBalance - amount);
        VM.deal(to, to.balance + amount);
        emit Transfer(from, to, amount);
    }
}
