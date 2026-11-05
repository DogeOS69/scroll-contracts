// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {Moat} from "../../dogeos/Moat.sol";
import {L2ScrollMessenger} from "../../L2/L2ScrollMessenger.sol";
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol";
import {AddressAliasHelper} from "../../libraries/common/AddressAliasHelper.sol";
import {ScrollConstants} from "../../libraries/constants/ScrollConstants.sol";
import {IScrollMessenger} from "../../libraries/IScrollMessenger.sol";
import {LegacyReplayCheck} from "../../../scripts/deterministic/LegacyReplayCheck.sol";
import {MoatTestBase} from "./MoatTestBase.t.sol";
import {ReferenceL2DogeOsMessenger} from "./reference/ReferenceL2DogeOsMessenger.sol";

/// @dev Deposit target that records the messenger's xDomainMessageSender while the relay runs,
///      and can be told to revert after reading it.
contract SenderProbe {
    IScrollMessenger internal immutable _messenger;
    address public seenSender;
    bool public revertAfterRead;

    constructor(IScrollMessenger messenger_) {
        _messenger = messenger_;
    }

    function setRevertAfterRead(bool value) external {
        revertAfterRead = value;
    }

    receive() external payable {
        seenSender = _messenger.xDomainMessageSender();
        require(!revertAfterRead, "probe revert");
    }
}

/// @dev Exposes the deploy/upgrade scripts' replay-check rules for testing.
contract LegacyReplayCheckHarness {
    function required(address proxy, bool initialized) external view returns (bool) {
        return LegacyReplayCheck.required(proxy, initialized);
    }

    function requireSafeUpgrade(
        address proxy,
        bool initialized,
        address newImpl,
        bool allowRollback
    ) external view {
        LegacyReplayCheck.requireSafeUpgrade(proxy, initialized, newImpl, allowRollback);
    }
}

/// @notice Upgrades a live messenger proxy from the pre-bitmap implementation (pinned as
///         ReferenceL2DogeOsMessenger) to the bitmap one, using the scripts' rule for
///         LEGACY_REPLAY_CHECK, and checks that deposits relayed before the upgrade can't be replayed.
contract L2DogeOsMessengerUpgradeTest is MoatTestBase {
    address internal constant L1_MESSENGER = address(0x1111);
    address internal constant L1_SENDER = address(0xabc);
    uint256 internal constant VALUE = 1 ether;

    L2MessageQueue internal _queue;
    ProxyAdmin internal _messengerAdmin;
    address internal _messengerProxy;
    address internal _moatProxy;
    Moat internal _moat;
    ReferenceL2DogeOsMessenger internal _legacyImpl;
    LegacyReplayCheckHarness internal _rules;

    function setUp() public {
        _rules = new LegacyReplayCheckHarness();
        _queue = new L2MessageQueue(address(this));
        (_messengerAdmin, _messengerProxy) = _deployEmptyProxy();
        ProxyAdmin moatAdmin;
        (moatAdmin, _moatProxy) = _deployEmptyProxy();

        // Live network before the upgrade: the proxy runs the pre-bitmap implementation.
        _legacyImpl = new ReferenceL2DogeOsMessenger(L1_MESSENGER, address(_queue), _moatProxy);
        _messengerAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(_messengerProxy),
            address(_legacyImpl),
            abi.encodeCall(L2ScrollMessenger.initialize, (address(0)))
        );
        _moat = _installMoat(
            moatAdmin,
            _moatProxy,
            _messengerProxy,
            MoatConfig({
                owner: address(this),
                feeRecipient: address(0xfee),
                withdrawalFee: 0,
                depositFee: 0,
                minWithdrawal: 0.01 ether,
                feeExemptCaller: address(0)
            })
        );
        vm.deal(_messengerProxy, 100 ether);
    }

    function _message(uint256 depositId) internal pure returns (bytes memory) {
        return abi.encodeCall(Moat.handleL1Message, (address(0xcafe), bytes32(depositId)));
    }

    function _relay(uint256 nonce, bytes memory message) internal {
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        L2ScrollMessenger(payable(_messengerProxy)).relayMessage(L1_SENDER, address(_moat), VALUE, nonce, message);
    }

    function _upgradeToBitmap(bool legacyReplayCheck) internal returns (L2DogeOsMessenger impl) {
        impl = new L2DogeOsMessenger(L1_MESSENGER, address(_queue), _moatProxy, legacyReplayCheck);
        _messengerAdmin.upgrade(ITransparentUpgradeableProxy(_messengerProxy), address(impl));
    }

    function _relayFrom(
        address from,
        address target,
        uint256 nonce
    ) internal {
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        L2ScrollMessenger(payable(_messengerProxy)).relayMessage(
            from,
            address(_moat),
            VALUE,
            nonce,
            abi.encodeCall(Moat.handleL1Message, (target, bytes32(nonce)))
        );
    }

    // --- Relay sender (the relay path moved into L2DogeOsMessenger._callMoat) --- //

    function test_SenderVisibleDuringRelayAndResetAfter() external {
        _upgradeToBitmap(true);
        IScrollMessenger messenger = IScrollMessenger(_messengerProxy);
        SenderProbe probe = new SenderProbe(messenger);

        assertEq(messenger.xDomainMessageSender(), ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER, "idle");
        _relayFrom(L1_SENDER, address(probe), 1);
        assertEq(probe.seenSender(), L1_SENDER, "sender during relay");
        assertEq(messenger.xDomainMessageSender(), ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER, "reset");
    }

    function test_ZeroSenderVisibleDuringRelay() external {
        _upgradeToBitmap(true);
        IScrollMessenger messenger = IScrollMessenger(_messengerProxy);
        SenderProbe probe = new SenderProbe(messenger);

        _relayFrom(address(0), address(probe), 2);
        assertEq(probe.seenSender(), address(0), "zero sender during relay");
        assertEq(messenger.xDomainMessageSender(), ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER, "reset");
    }

    function test_SenderResetAfterFailedRelay() external {
        _upgradeToBitmap(true);
        IScrollMessenger messenger = IScrollMessenger(_messengerProxy);
        SenderProbe probe = new SenderProbe(messenger);
        probe.setRevertAfterRead(true);

        _relayFrom(L1_SENDER, address(probe), 3);
        assertFalse(L2DogeOsMessenger(payable(_messengerProxy)).isL1MessageNonceExecuted(3), "relay failed");
        assertEq(messenger.xDomainMessageSender(), ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER, "reset");
    }

    function test_DefaultSenderRejected() external {
        _upgradeToBitmap(true);
        vm.expectRevert("Invalid message sender");
        _relayFrom(ScrollConstants.DEFAULT_XDOMAIN_MESSAGE_SENDER, address(0xcafe), 4);
    }

    // --- Upgrade from the pre-bitmap implementation --- //

    function test_DepositRelayedBeforeUpgradeCannotBeReplayed() external {
        _relay(5, _message(5)); // recorded in the per-hash mapping by the legacy implementation
        assertEq(address(0xcafe).balance, VALUE);

        bool required = _rules.required(_messengerProxy, true);
        assertTrue(required, "pre-bitmap proxy requires the legacy check");
        L2DogeOsMessenger impl = new L2DogeOsMessenger(L1_MESSENGER, address(_queue), _moatProxy, required);
        _rules.requireSafeUpgrade(_messengerProxy, true, address(impl), false);
        _messengerAdmin.upgrade(ITransparentUpgradeableProxy(_messengerProxy), address(impl));

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        vm.expectRevert("Message was already successfully executed");
        L2ScrollMessenger(payable(_messengerProxy)).relayMessage(L1_SENDER, address(_moat), VALUE, 5, _message(5));

        _relay(6, _message(6)); // new deposits use the bitmap
        assertTrue(L2DogeOsMessenger(payable(_messengerProxy)).isL1MessageNonceExecuted(6));
        assertEq(address(0xcafe).balance, 2 * VALUE, "each deposit credited once");
    }

    /// @dev Why the rule exists: without the legacy check the pre-upgrade deposit is replayable.
    function test_WithoutLegacyCheckAPreUpgradeDepositWouldBeReplayable() external {
        _relay(5, _message(5));
        _upgradeToBitmap(false);
        _relay(5, _message(5));
        assertEq(address(0xcafe).balance, 2 * VALUE, "double credit");
    }

    function test_UpgradeRefusedWhenItTurnsTheLegacyCheckOff() external {
        L2DogeOsMessenger withoutCheck = new L2DogeOsMessenger(L1_MESSENGER, address(_queue), _moatProxy, false);
        vm.expectRevert("new L2DogeOsMessenger implementation must keep LEGACY_REPLAY_CHECK");
        _rules.requireSafeUpgrade(_messengerProxy, true, address(withoutCheck), false);

        // Once on the bitmap with the check, it stays required for every later upgrade.
        _upgradeToBitmap(true);
        assertTrue(_rules.required(_messengerProxy, true), "sticky");
        vm.expectRevert("new L2DogeOsMessenger implementation must keep LEGACY_REPLAY_CHECK");
        _rules.requireSafeUpgrade(_messengerProxy, true, address(withoutCheck), false);
    }

    function test_RollbackToPreBitmapRefusedUnlessAllowed() external {
        _upgradeToBitmap(true);
        vm.expectRevert(
            "rollback to a pre-bitmap L2DogeOsMessenger drops replay protection for deposits relayed since the upgrade"
        );
        _rules.requireSafeUpgrade(_messengerProxy, true, address(_legacyImpl), false);
        _rules.requireSafeUpgrade(_messengerProxy, true, address(_legacyImpl), true); // explicit override
    }

    /// @dev A fresh network: uninitialized proxy -> no legacy check; after the bitmap
    ///      implementation (without the check) is installed, reruns keep it off.
    function test_FreshMessengerNeedsNoLegacyCheckAndRerunsKeepIt() external {
        (ProxyAdmin admin, address freshProxy) = _deployEmptyProxy();
        assertFalse(_rules.required(freshProxy, false), "uninitialized");

        L2DogeOsMessenger impl = new L2DogeOsMessenger(L1_MESSENGER, address(_queue), _moatProxy, false);
        // DeployScroll's flow: upgrade, then initialize in a separate call.
        admin.upgrade(ITransparentUpgradeableProxy(freshProxy), address(impl));
        L2ScrollMessenger(payable(freshProxy)).initialize(L1_MESSENGER);
        assertFalse(_rules.required(freshProxy, true), "bitmap without the check keeps it off");
        _rules.requireSafeUpgrade(freshProxy, true, address(impl), false); // rerun with the same implementation
    }
}
