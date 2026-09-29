// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {Moat} from "../../dogeos/Moat.sol";
import {MockScrollMessenger} from "./Moat.t.sol";
import {MoatTestBase} from "./MoatTestBase.t.sol";

/// @dev Sends its balance to a target with SELFDESTRUCT, which bypasses the target's code.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Fee recipient that tries to re-enter the Moat when paid, and records the revert reason.
contract ReentrantReceiver {
    Moat internal immutable _moat;
    string public reentryError;
    bool public reentered;

    constructor(Moat moat_) {
        _moat = moat_;
    }

    receive() external payable {
        try _moat.withdrawToP2PKH{value: msg.value}(address(0x1111)) {
            reentered = true;
        } catch Error(string memory reason) {
            reentryError = reason;
        }
    }
}

/// @notice Fees are held by the Moat and paid to the current feeRecipient by sweepFees().
contract MoatFeeSweepTest is MoatTestBase {
    uint256 internal constant WITHDRAWAL_FEE = 0.01 ether;
    uint256 internal constant DEPOSIT_FEE = 0.02 ether;
    uint256 internal constant MIN_WITHDRAWAL = 0.1 ether;

    address internal _owner = address(0x1);
    address payable internal _recipientA = payable(address(0xa11));
    address payable internal _recipientB = payable(address(0xb22));
    address internal _user = address(0x2);

    MockScrollMessenger internal _messenger;
    Moat internal _moat;

    event FeesSwept(address indexed recipient, uint256 amount);

    function setUp() public {
        _messenger = new MockScrollMessenger(address(0xbeef));
        _moat = _deployMoat(
            address(_messenger),
            MoatConfig({
                owner: _owner,
                feeRecipient: _recipientA,
                withdrawalFee: WITHDRAWAL_FEE,
                depositFee: DEPOSIT_FEE,
                minWithdrawal: MIN_WITHDRAWAL,
                feeExemptCaller: address(0)
            })
        );
        vm.deal(_user, 100 ether);
        vm.deal(address(_messenger), 100 ether);
    }

    function _withdraw(uint256 value) internal {
        vm.prank(_user);
        _moat.withdrawToP2PKH{value: value}(address(0x1111));
    }

    function _deposit(uint256 value) internal {
        vm.prank(address(_messenger));
        _moat.handleL1Message{value: value}(address(0xcafe), bytes32(0));
    }

    /// @dev The Moat calls the fee recipient only in sweepFees, which is guarded: a recipient
    ///      that tries to re-enter a guarded entry point is blocked.
    function test_FeeRecipientCannotReenterMoatDuringSweep() external {
        (ProxyAdmin admin, address proxy) = _deployEmptyProxy();
        ReentrantReceiver recipient = new ReentrantReceiver(Moat(proxy));
        Moat moat = _installMoat(
            admin,
            proxy,
            address(_messenger),
            MoatConfig({
                owner: _owner,
                feeRecipient: address(recipient),
                withdrawalFee: 1 ether,
                depositFee: 0,
                minWithdrawal: MIN_WITHDRAWAL,
                feeExemptCaller: address(0)
            })
        );

        vm.prank(_user);
        moat.withdrawToP2PKH{value: 2 ether}(address(0x2222)); // 1 ether fee held
        moat.sweepFees(); // pays 1 ether; the recipient tries to re-enter
        assertFalse(recipient.reentered(), "re-entry blocked");
        assertEq(recipient.reentryError(), "ReentrancyGuard: reentrant call");
        assertEq(address(recipient).balance, 1 ether, "fee swept");
    }

    function test_FeesAreHeldUntilSwept() external {
        _withdraw(1 ether + WITHDRAWAL_FEE + 7); // 7 wei of dust joins the fee
        _deposit(1 ether);

        uint256 expected = WITHDRAWAL_FEE + 7 + DEPOSIT_FEE;
        assertEq(address(_moat).balance, expected, "held");
        assertEq(_recipientA.balance, 0, "not paid yet");

        vm.expectEmit(true, false, false, true, address(_moat));
        emit FeesSwept(_recipientA, expected);
        assertEq(_moat.sweepFees(), expected);
        assertEq(_recipientA.balance, expected, "swept");
        assertEq(address(_moat).balance, 0, "nothing left");
    }

    function test_SweepIsPermissionlessAndPaysOnlyTheRecipient() external {
        _withdraw(1 ether + WITHDRAWAL_FEE);
        address anyone = address(0xdead);
        vm.prank(anyone);
        _moat.sweepFees();
        assertEq(_recipientA.balance, WITHDRAWAL_FEE);
        assertEq(anyone.balance, 0);
    }

    function test_EmptySweepIsANoOp() external {
        vm.recordLogs();
        assertEq(_moat.sweepFees(), 0);
        assertEq(vm.getRecordedLogs().length, 0, "no event");
    }

    /// @dev Chosen policy: fees held when the recipient changes go to the recipient that is
    ///      current at sweep time.
    function test_RotationPaysTheCurrentRecipient() external {
        _withdraw(1 ether + WITHDRAWAL_FEE);
        vm.prank(_owner);
        _moat.setFeeRecipient(_recipientB);

        _moat.sweepFees();
        assertEq(_recipientA.balance, 0, "outgoing recipient not paid");
        assertEq(_recipientB.balance, WITHDRAWAL_FEE, "current recipient paid");
    }

    /// @dev Operators who want the outgoing recipient paid sweep before rotating.
    function test_SweepBeforeRotationPaysTheOutgoingRecipient() external {
        _withdraw(1 ether + WITHDRAWAL_FEE);
        _moat.sweepFees();
        vm.prank(_owner);
        _moat.setFeeRecipient(_recipientB);
        _deposit(1 ether);
        _moat.sweepFees();

        assertEq(_recipientA.balance, WITHDRAWAL_FEE, "outgoing paid for its period");
        assertEq(_recipientB.balance, DEPOSIT_FEE, "new recipient paid for its period");
    }

    /// @dev A deposit at or below the fee is kept whole as the fee.
    function test_DepositNotAboveFeeIsKeptWhole() external {
        _deposit(DEPOSIT_FEE);
        assertEq(address(_moat).balance, DEPOSIT_FEE);
        assertEq(address(0xcafe).balance, 0, "target not paid");
    }

    /// @dev Value force-sent to the Moat (it has no receive function) is swept like fees.
    function test_ForcedValueIsSwept() external {
        new ForceSender{value: 1 ether}(payable(address(_moat)));
        _withdraw(1 ether + WITHDRAWAL_FEE);
        assertEq(_moat.sweepFees(), 1 ether + WITHDRAWAL_FEE);
        assertEq(_recipientA.balance, 1 ether + WITHDRAWAL_FEE);
    }

    /// @dev The Moat's balance is exactly the fees reported by its events (conservation):
    ///      every operation keeps its fee and forwards the rest.
    function testFuzz_HeldFeesMatchReportedFees(uint96[6] memory amounts, uint8 mask) external {
        uint256 reported;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 value = bound(amounts[i], 0, 10 ether);
            if ((mask >> i) & 1 == 1) {
                // withdrawal (must cover fee + minimum)
                value = bound(value, WITHDRAWAL_FEE + MIN_WITHDRAWAL + 1e10, 10 ether);
                uint256 afterFee = value - WITHDRAWAL_FEE;
                reported += WITHDRAWAL_FEE + (afterFee % 1e10);
                _withdraw(value);
            } else {
                reported += value <= DEPOSIT_FEE ? value : DEPOSIT_FEE;
                _deposit(value);
            }
        }
        assertEq(address(_moat).balance, reported, "held == reported fees");
        assertEq(_moat.sweepFees(), reported);
        assertEq(_recipientA.balance, reported);
    }
}
