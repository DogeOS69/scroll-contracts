// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {Moat} from "../../dogeos/Moat.sol";
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol";
import {AddressAliasHelper} from "../../libraries/common/AddressAliasHelper.sol";
import {MoatTestBase} from "./MoatTestBase.t.sol";

/// @dev Tries to re-enter the Moat when it receives value (as a deposit target or as the fee
///      recipient) and records the revert reason instead of failing.
contract ReentrantReceiver {
    Moat internal immutable _moat;
    string public reentryError;
    bool public reentered;

    constructor(Moat moat_) {
        _moat = moat_;
    }

    receive() external payable {
        if (msg.value < 1 ether) {
            return; // don't recurse on small amounts
        }
        try _moat.withdrawToP2PKH{value: msg.value}(address(0x1111)) {
            reentered = true;
        } catch Error(string memory reason) {
            reentryError = reason;
        }
    }
}

/// @notice Transient-storage reentrancy guard on the Moat's entry points and the messenger's
///         send path.
contract TransientReentrancyGuardTest is MoatTestBase {
    address internal constant L1_MESSENGER = address(0x1111);
    /// @dev OZ ReentrancyGuardUpgradeable `_status` slots, kept for layout and no longer used.
    uint256 internal constant MOAT_OZ_STATUS_SLOT = 1;
    uint256 internal constant MESSENGER_OZ_STATUS_SLOT = 151;

    L2MessageQueue internal _queue;
    L2DogeOsMessenger internal _messenger;
    Moat internal _moat;
    ProxyAdmin internal _admin;
    address internal _moatProxy;

    function setUp() public {
        _queue = new L2MessageQueue(address(this));
        (_admin, _moatProxy) = _deployEmptyProxy();
        _messenger = new L2DogeOsMessenger(L1_MESSENGER, address(_queue), _moatProxy, false);
        _queue.initialize(address(_messenger));
        vm.deal(address(_messenger), 1_000 ether);
    }

    function _install(address feeRecipient, uint256 withdrawalFee) internal {
        _moat = _installMoat(
            _admin,
            _moatProxy,
            address(_messenger),
            MoatConfig({
                owner: address(this),
                feeRecipient: feeRecipient,
                withdrawalFee: withdrawalFee,
                depositFee: 0,
                minWithdrawal: 0.01 ether,
                feeExemptCaller: address(0)
            })
        );
    }

    function _relay(
        address from,
        address target,
        uint256 nonce
    ) internal {
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        _messenger.relayMessage(
            from,
            address(_moat),
            1 ether,
            nonce,
            abi.encodeCall(Moat.handleL1Message, (target, bytes32(nonce)))
        );
    }

    // --- Transient reentrancy guard --- //

    function test_DepositTargetCannotReenterMoat() external {
        _install(address(0xfee), 0);
        ReentrantReceiver target = new ReentrantReceiver(_moat);

        _relay(address(0xabc), address(target), 6);
        assertFalse(target.reentered(), "re-entry blocked");
        assertEq(target.reentryError(), "ReentrancyGuard: reentrant call");
        assertTrue(_messenger.isL1MessageNonceExecuted(6), "deposit itself succeeded");
    }

    function test_FeeRecipientCannotReenterMoat() external {
        ReentrantReceiver recipient = new ReentrantReceiver(Moat(_moatProxy));
        _install(address(recipient), 1 ether); // the fee payment triggers the re-entry attempt

        vm.deal(address(this), 3 ether);
        _moat.withdrawToP2PKH{value: 2 ether}(address(0x2222));
        assertFalse(recipient.reentered(), "re-entry blocked");
        assertEq(recipient.reentryError(), "ReentrancyGuard: reentrant call");
    }

    /// @dev The guard is released on exit, not just at the end of the transaction: two guarded
    ///      calls in the same transaction (one Foundry test) both succeed.
    function test_GuardReleasedWithinTransaction() external {
        _install(address(0xfee), 0);
        vm.deal(address(this), 3 ether);
        _moat.withdrawToP2PKH{value: 1 ether}(address(0x3333));
        _moat.withdrawToP2SH{value: 1 ether}(address(0x4444));
        assertEq(_queue.nextMessageIndex(), 2);
    }

    /// @dev The OZ guard's persistent `_status` slots stay in place for layout but are unused.
    function test_OzStatusSlotsUntouched() external {
        _install(address(0xfee), 0);
        bytes32 moatStatus = vm.load(address(_moat), bytes32(MOAT_OZ_STATUS_SLOT));
        bytes32 messengerStatus = vm.load(address(_messenger), bytes32(MESSENGER_OZ_STATUS_SLOT));

        vm.deal(address(this), 1 ether);
        _moat.withdrawToP2PKH{value: 1 ether}(address(0x5555));
        _relay(address(0xabc), address(0xcafe), 7);

        assertEq(vm.load(address(_moat), bytes32(MOAT_OZ_STATUS_SLOT)), moatStatus, "Moat _status");
        assertEq(vm.load(address(_messenger), bytes32(MESSENGER_OZ_STATUS_SLOT)), messengerStatus, "messenger _status");
    }
}
