// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

import {INativeDoge} from "../../dogeos/INativeDoge.sol";
import {DualityDogeShim} from "../mocks/DualityDogeShim.sol";

/// @dev Recipient with a reverting receive(): duality transfers must NOT execute
///      recipient code, so sending to this contract must still succeed.
contract RevertingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

contract DualityDogeShimTest is Test {
    INativeDoge internal _doge;

    address internal _alice = makeAddr("alice");
    address internal _bob = makeAddr("bob");

    function setUp() public {
        _doge = new DualityDogeShim();
        vm.deal(_alice, 100 ether);
    }

    function testBalanceOfIsNativeBalance() external {
        assertEq(_doge.balanceOf(_alice), _alice.balance);
        assertEq(_doge.balanceOf(_alice), 100 ether);
        vm.deal(_bob, 7 ether);
        assertEq(_doge.balanceOf(_bob), 7 ether);
    }

    function testTransferMovesNativeBalance() external {
        vm.prank(_alice);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(_alice, _bob, 30 ether);
        assertTrue(_doge.transfer(_bob, 30 ether));

        assertEq(_alice.balance, 70 ether);
        assertEq(_bob.balance, 30 ether);
    }

    function testTransferToSelfIsNoop() external {
        vm.prank(_alice);
        _doge.transfer(_alice, 40 ether);
        assertEq(_alice.balance, 100 ether);
    }

    function testTransferZeroAmount() external {
        vm.prank(_alice);
        assertTrue(_doge.transfer(_bob, 0));
        assertEq(_alice.balance, 100 ether);
        assertEq(_bob.balance, 0);
    }

    function testTransferInsufficientBalanceReverts() external {
        vm.prank(_alice);
        vm.expectRevert(
            abi.encodeWithSelector(DualityDogeShim.ErrorInsufficientBalance.selector, _alice, 100 ether, 101 ether)
        );
        _doge.transfer(_bob, 101 ether);
    }

    /// @dev Production duality moves balance without executing recipient code; the
    ///      shim must match - a reverting receive() cannot block the transfer.
    function testTransferDoesNotExecuteRecipientCode() external {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.prank(_alice);
        assertTrue(_doge.transfer(address(receiver), 5 ether));
        assertEq(address(receiver).balance, 5 ether);
    }

    function testApproveAndTransferFrom() external {
        vm.prank(_alice);
        _doge.approve(_bob, 25 ether);
        assertEq(_doge.allowance(_alice, _bob), 25 ether);

        vm.prank(_bob);
        assertTrue(_doge.transferFrom(_alice, _bob, 10 ether));

        assertEq(_alice.balance, 90 ether);
        assertEq(_bob.balance, 10 ether);
        assertEq(_doge.allowance(_alice, _bob), 15 ether);
    }

    function testTransferFromInfiniteAllowanceNotDecremented() external {
        vm.prank(_alice);
        _doge.approve(_bob, type(uint256).max);

        vm.prank(_bob);
        _doge.transferFrom(_alice, _bob, 10 ether);
        assertEq(_doge.allowance(_alice, _bob), type(uint256).max);
    }

    function testTransferFromInsufficientAllowanceReverts() external {
        vm.prank(_alice);
        _doge.approve(_bob, 5 ether);

        vm.prank(_bob);
        vm.expectRevert(
            abi.encodeWithSelector(DualityDogeShim.ErrorInsufficientAllowance.selector, _alice, _bob, 5 ether, 6 ether)
        );
        _doge.transferFrom(_alice, _bob, 6 ether);
    }

    function testTransferFromInsufficientBalanceReverts() external {
        vm.prank(_alice);
        _doge.approve(_bob, type(uint256).max);

        vm.prank(_bob);
        vm.expectRevert(
            abi.encodeWithSelector(DualityDogeShim.ErrorInsufficientBalance.selector, _alice, 100 ether, 101 ether)
        );
        _doge.transferFrom(_alice, _bob, 101 ether);
    }

    function testFuzz_TransferConservesTotal(uint256 amount) external {
        amount = bound(amount, 0, 100 ether);
        uint256 totalBefore = _alice.balance + _bob.balance;

        vm.prank(_alice);
        _doge.transfer(_bob, amount);

        assertEq(_alice.balance + _bob.balance, totalBefore);
        assertEq(_bob.balance, amount);
    }
}
