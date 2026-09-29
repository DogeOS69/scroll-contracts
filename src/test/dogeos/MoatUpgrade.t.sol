// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Moat} from "../../dogeos/Moat.sol";
import {ReferenceMoat} from "./reference/ReferenceMoat.sol";
import {MockScrollMessenger} from "./Moat.t.sol";

/// @notice Upgrades a proxy running the pre-change Moat (pinned as ReferenceMoat) to the
///         current implementation and checks storage, the messenger binding, and live
///         behavior, the same way an existing network is upgraded.
contract MoatUpgradeTest is Test {
    /// @dev Storage slot of the former `messenger` variable, now `_deprecatedMessengerSlot`.
    uint256 internal constant DEPRECATED_MESSENGER_SLOT = 51;
    /// @dev Storage slot of the `feeExemptCallers` mapping (see testFeeExemptCallersStorageSlot).
    uint256 internal constant FEE_EXEMPT_CALLERS_SLOT = 57;
    /// @dev Covers OwnableBase, Initializable, ReentrancyGuard (+ gap) and every Moat variable.
    uint256 internal constant SNAPSHOT_SLOTS = 64;

    uint256 internal constant WITHDRAWAL_FEE = 0.01 ether;
    uint256 internal constant DEPOSIT_FEE = 0.02 ether;
    uint256 internal constant MIN_WITHDRAWAL = 0.1 ether;

    address internal _owner = address(0x1);
    address internal _user = address(0x2);
    address payable internal _feeRecipient = payable(address(0xfee));
    address internal _exemptCaller = address(0xada9);

    ProxyAdmin internal _admin;
    TransparentUpgradeableProxy internal _proxy;
    MockScrollMessenger internal _messenger;
    ReferenceMoat internal _referenceImpl;

    function setUp() public {
        _messenger = new MockScrollMessenger(address(0xbeef));
        _admin = new ProxyAdmin();

        // An existing network: proxy on the pre-change implementation, configured through
        // its owner setters (including the since-removed updateMessenger).
        _referenceImpl = new ReferenceMoat(bytes1(0x1e), bytes1(0x16));
        _proxy = new TransparentUpgradeableProxy(
            address(_referenceImpl),
            address(_admin),
            abi.encodeCall(ReferenceMoat.initialize, (_owner))
        );
        ReferenceMoat live = ReferenceMoat(address(_proxy));
        vm.startPrank(_owner);
        live.updateMessenger(address(_messenger));
        live.setFeeRecipient(_feeRecipient);
        live.setWithdrawalFee(WITHDRAWAL_FEE);
        live.setDepositFee(DEPOSIT_FEE);
        live.setMinWithdrawal(MIN_WITHDRAWAL);
        live.setFeeExempt(_exemptCaller, true);
        vm.stopPrank();
    }

    function _snapshot() internal view returns (bytes32[] memory slots) {
        slots = new bytes32[](SNAPSHOT_SLOTS);
        for (uint256 i = 0; i < SNAPSHOT_SLOTS; i++) {
            slots[i] = vm.load(address(_proxy), bytes32(i));
        }
    }

    function _upgradeToCurrent() internal returns (Moat moat) {
        Moat newImpl = new Moat(bytes1(0x1e), bytes1(0x16), address(_messenger));
        _admin.upgrade(ITransparentUpgradeableProxy(address(_proxy)), address(newImpl));
        moat = Moat(address(_proxy));
    }

    function test_Upgrade_PreservesStorage() external {
        bytes32[] memory before = _snapshot();
        bytes32 exemptSlot = keccak256(abi.encode(_exemptCaller, FEE_EXEMPT_CALLERS_SLOT));
        bytes32 exemptBefore = vm.load(address(_proxy), exemptSlot);

        Moat moat = _upgradeToCurrent();

        bytes32[] memory afterUpgrade = _snapshot();
        for (uint256 i = 0; i < SNAPSHOT_SLOTS; i++) {
            assertEq(afterUpgrade[i], before[i], string.concat("storage slot changed: ", vm.toString(i)));
        }
        assertEq(vm.load(address(_proxy), exemptSlot), exemptBefore, "feeExemptCallers entry changed");

        assertEq(moat.owner(), _owner, "owner");
        assertEq(moat.withdrawalFee(), WITHDRAWAL_FEE, "withdrawalFee");
        assertEq(moat.depositFee(), DEPOSIT_FEE, "depositFee");
        assertEq(moat.minWithdrawalAmount(), MIN_WITHDRAWAL, "minWithdrawalAmount");
        assertEq(moat.feeRecipient(), _feeRecipient, "feeRecipient");
        assertTrue(moat.feeExemptCallers(_exemptCaller), "feeExemptCallers");
    }

    function test_Upgrade_MessengerIsBoundImmutableAndOldSlotKept() external {
        Moat moat = _upgradeToCurrent();

        assertEq(moat.MESSENGER(), address(_messenger), "MESSENGER");
        assertEq(moat.messenger(), address(_messenger), "messenger()");
        assertEq(
            address(uint160(uint256(vm.load(address(_proxy), bytes32(DEPRECATED_MESSENGER_SLOT))))),
            address(_messenger),
            "deprecated messenger slot must keep the old value"
        );

        vm.prank(_owner);
        (bool success, ) = address(moat).call(abi.encodeWithSignature("updateMessenger(address)", address(0xabcd)));
        assertFalse(success, "updateMessenger must not exist after the upgrade");
    }

    function test_Upgrade_DepositAndWithdrawalWork() external {
        Moat moat = _upgradeToCurrent();

        // Deposit relayed by the bound messenger.
        address target = address(0xdead);
        vm.deal(address(_messenger), 1 ether);
        vm.prank(address(_messenger));
        moat.handleL1Message{value: 1 ether}(target, bytes32(0));
        assertEq(target.balance, 1 ether - DEPOSIT_FEE, "deposit credited");
        assertEq(_feeRecipient.balance, DEPOSIT_FEE, "deposit fee collected");

        // Withdrawal sent through the bound messenger.
        vm.deal(_user, 1 ether);
        vm.prank(_user);
        moat.withdrawToP2PKH{value: 0.5 ether + WITHDRAWAL_FEE}(address(0x1111));
        assertEq(_messenger.lastSender(), address(moat), "withdrawal sent by the Moat");
        assertEq(_messenger.lastValue(), 0.5 ether, "withdrawal amount");
    }

    function test_Upgrade_InitializeCannotRerun() external {
        Moat moat = _upgradeToCurrent();

        vm.expectRevert("Initializable: contract is already initialized");
        moat.initialize(_user);
    }

    /// @dev Rolling back to the pre-change implementation must keep working, because the
    ///      deprecated slot still holds the messenger the old code reads.
    function test_Rollback_ToReferenceStillWorks() external {
        _upgradeToCurrent();
        _admin.upgrade(ITransparentUpgradeableProxy(address(_proxy)), address(_referenceImpl));
        ReferenceMoat rolledBack = ReferenceMoat(address(_proxy));

        assertEq(rolledBack.messenger(), address(_messenger), "rolled-back messenger()");

        vm.deal(_user, 1 ether);
        vm.prank(_user);
        rolledBack.withdrawToP2PKH{value: 0.5 ether + WITHDRAWAL_FEE}(address(0x1111));
        assertEq(_messenger.lastValue(), 0.5 ether, "withdrawal after rollback");
    }
}
