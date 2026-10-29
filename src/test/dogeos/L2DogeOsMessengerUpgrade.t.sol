// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {Moat} from "../../dogeos/Moat.sol";
import {WithdrawalEnvelope} from "../../dogeos/WithdrawalEnvelope.sol";
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol";
import {AddressAliasHelper} from "../../libraries/common/AddressAliasHelper.sol";
import {IScrollMessenger} from "../../libraries/IScrollMessenger.sol";
import {MoatTestBase} from "./MoatTestBase.t.sol";

/// @notice Upgrades an L2DogeOsMessenger proxy to a fresh implementation through its
///         ProxyAdmin, the way an existing network is upgraded, and checks that every
///         storage variable survives and that the messenger still works afterwards.
/// @dev The proxy keeps its state across an implementation change, so the test first
///      brings it into a state no fresh deployment has: an owner, a fee vault, a pause, an
///      executed L1 message, a sent withdrawal, and a `messageSendTimestamp` entry from
///      before the send path stopped writing that mapping. Slots the current source only
///      reserves (`__counterpart`, `__rateLimiter`, `__used`) are seeded directly, because
///      a network upgraded from an older implementation holds values there.
///
///      The messenger keeps no whitelist and no counter of its own: who may call it is the
///      `owner` plus the immutable `MOAT`, and the message nonce lives in the
///      L2MessageQueue, checked here across the upgrade as well.
contract L2DogeOsMessengerUpgradeTest is MoatTestBase {
    /// @dev Slots of the messenger's variables; see storage-layouts/L2DogeOsMessenger.json.
    uint256 internal constant OWNER_SLOT = 51;
    uint256 internal constant PAUSED_SLOT = 101;
    uint256 internal constant STATUS_SLOT = 151;
    uint256 internal constant XDOMAIN_MESSAGE_SENDER_SLOT = 201;
    uint256 internal constant DEPRECATED_COUNTERPART_SLOT = 202;
    uint256 internal constant FEE_VAULT_SLOT = 203;
    uint256 internal constant DEPRECATED_RATE_LIMITER_SLOT = 204;
    uint256 internal constant MESSAGE_SEND_TIMESTAMP_SLOT = 251;
    uint256 internal constant IS_L1_MESSAGE_EXECUTED_SLOT = 252;
    uint256 internal constant USED_SLOT = 253;
    /// @dev Covers every variable, up to and including `__used[1]` at slot 254.
    uint256 internal constant SNAPSHOT_SLOTS = 256;

    /// @dev Sentinels for the slots the current source reserves but never writes.
    bytes32 internal constant DEPRECATED_COUNTERPART_VALUE = bytes32(uint256(0xc0c0));
    bytes32 internal constant DEPRECATED_RATE_LIMITER_VALUE = bytes32(uint256(0xa1a1));
    bytes32 internal constant USED_0_VALUE = bytes32(uint256(0x5e0));
    bytes32 internal constant USED_1_VALUE = bytes32(uint256(0x5e1));

    /// @dev A message sent before the upgrade that stopped writing `messageSendTimestamp`.
    bytes32 internal constant LEGACY_MESSAGE_HASH = keccak256("a withdrawal sent before this upgrade");
    uint256 internal constant LEGACY_SEND_TIMESTAMP = 1_700_000_000;

    uint256 internal constant WITHDRAWAL = 0.5 ether;
    uint256 internal constant DEPOSIT = 1 ether;
    uint256 internal constant MIN_WITHDRAWAL = 0.01 ether;

    address internal _l1Counterpart = address(0xc0117e42);
    address internal _owner = address(0x1);
    address internal _user = address(0x2);
    address internal _feeVault = address(0xfa17);

    ProxyAdmin internal _admin;
    TransparentUpgradeableProxy internal _proxy;
    L2MessageQueue internal _queue;
    L2DogeOsMessenger internal _messenger;
    Moat internal _moat;

    function setUp() public {
        _queue = new L2MessageQueue(address(this));
        _admin = new ProxyAdmin();

        // Same order as DeployScroll: both proxies exist first, so the messenger and the
        // Moat can bind each other's address immutably, then the implementations go in.
        (ProxyAdmin moatAdmin, address moatProxy) = _deployEmptyProxy();
        L2DogeOsMessenger implementation = new L2DogeOsMessenger(_l1Counterpart, address(_queue), moatProxy);
        _proxy = new TransparentUpgradeableProxy(address(implementation), address(_admin), new bytes(0));
        _messenger = L2DogeOsMessenger(payable(address(_proxy)));
        vm.prank(_owner);
        _messenger.initialize(_l1Counterpart);

        _moat = _installMoat(
            moatAdmin,
            moatProxy,
            address(_messenger),
            MoatConfig({
                owner: _owner,
                feeRecipient: address(0xfee),
                withdrawalFee: 0,
                depositFee: 0,
                minWithdrawal: MIN_WITHDRAWAL,
                feeExemptCaller: address(0)
            })
        );
        _queue.initialize(address(_messenger));

        // State an existing network carries into the upgrade.
        vm.prank(_owner);
        _messenger.updateFeeVault(_feeVault);
        vm.store(address(_proxy), bytes32(DEPRECATED_COUNTERPART_SLOT), DEPRECATED_COUNTERPART_VALUE);
        vm.store(address(_proxy), bytes32(DEPRECATED_RATE_LIMITER_SLOT), DEPRECATED_RATE_LIMITER_VALUE);
        vm.store(address(_proxy), bytes32(USED_SLOT), USED_0_VALUE);
        vm.store(address(_proxy), bytes32(USED_SLOT + 1), USED_1_VALUE);
        vm.store(address(_proxy), _timestampSlot(LEGACY_MESSAGE_HASH), bytes32(LEGACY_SEND_TIMESTAMP));
    }

    /// @dev The hash the messenger records for a relayed L1 message, and the one it
    ///      commits to the queue for a message sent to L1.
    function _messageHash(
        address from,
        address to,
        uint256 value,
        uint256 nonce,
        bytes memory message
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodeWithSignature(
                    "relayMessage(address,address,uint256,uint256,bytes)",
                    from,
                    to,
                    value,
                    nonce,
                    message
                )
            );
    }

    function _timestampSlot(bytes32 messageHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(messageHash, MESSAGE_SEND_TIMESTAMP_SLOT));
    }

    function _depositMessage(address recipient) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("handleL1Message(address,bytes32)", recipient, bytes32(0));
    }

    function _freshImplementation() internal returns (L2DogeOsMessenger) {
        return new L2DogeOsMessenger(_l1Counterpart, address(_queue), address(_moat));
    }

    function _snapshot() internal view returns (bytes32[] memory slots) {
        slots = new bytes32[](SNAPSHOT_SLOTS);
        for (uint256 i = 0; i < SNAPSHOT_SLOTS; i++) {
            slots[i] = vm.load(address(_proxy), bytes32(i));
        }
    }

    function _upgradeToFresh() internal returns (L2DogeOsMessenger upgraded) {
        _admin.upgrade(ITransparentUpgradeableProxy(address(_proxy)), address(_freshImplementation()));
        upgraded = L2DogeOsMessenger(payable(address(_proxy)));
    }

    /// @dev Relays one deposit to the Moat, which forwards it to `recipient`.
    function _relayDeposit(address recipient, uint256 nonce) internal returns (bytes32 relayHash) {
        bytes memory message = _depositMessage(recipient);
        relayHash = _messageHash(_l1Counterpart, address(_moat), DEPOSIT, nonce, message);
        vm.deal(address(_proxy), DEPOSIT);
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(_l1Counterpart));
        _messenger.relayMessage({
            _from: _l1Counterpart,
            _to: address(_moat),
            _value: DEPOSIT,
            _nonce: nonce,
            _message: message
        });
    }

    /// @dev One withdrawal through the Moat, the only account allowed to send L2 -> L1.
    ///      With no withdrawal fee and a satoshi-aligned amount, the whole value is sent.
    function _withdraw(address target) internal returns (bytes32 sentHash) {
        uint256 nonce = _queue.nextMessageIndex();
        sentHash = _messageHash(address(_moat), target, WITHDRAWAL, nonce, WithdrawalEnvelope.encode(false));
        vm.deal(_user, WITHDRAWAL);
        vm.prank(_user);
        _moat.withdrawToP2PKH{value: WITHDRAWAL}(target);
    }

    function test_Upgrade_PreservesStorage() external {
        bytes32 executedHash = _relayDeposit(address(0xdef), 1);
        bytes32 sentHash = _withdraw(address(0x1111));
        vm.prank(_owner);
        _messenger.setPause(true);

        bytes32[] memory before = _snapshot();
        uint256 queueIndexBefore = _queue.nextMessageIndex();
        bytes32 rootBefore = _queue.messageRoot();

        L2DogeOsMessenger upgraded = _upgradeToFresh();

        bytes32[] memory afterUpgrade = _snapshot();
        for (uint256 i = 0; i < SNAPSHOT_SLOTS; i++) {
            assertEq(afterUpgrade[i], before[i], string.concat("storage slot changed: ", vm.toString(i)));
        }

        // Initializable: initialized, and no longer initializing.
        assertEq(uint256(afterUpgrade[0]), 1, "_initialized/_initializing");
        // OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable.
        assertEq(upgraded.owner(), _owner, "owner");
        assertEq(address(uint160(uint256(afterUpgrade[OWNER_SLOT]))), _owner, "_owner slot");
        assertTrue(upgraded.paused(), "paused");
        assertEq(uint256(afterUpgrade[PAUSED_SLOT]), 1, "_paused slot");
        assertEq(uint256(afterUpgrade[STATUS_SLOT]), 1, "_status slot (not entered)");
        // ScrollMessengerBase.
        assertEq(upgraded.xDomainMessageSender(), address(1), "xDomainMessageSender");
        assertEq(
            address(uint160(uint256(afterUpgrade[XDOMAIN_MESSAGE_SENDER_SLOT]))),
            address(1),
            "xDomainMessageSender slot"
        );
        assertEq(upgraded.feeVault(), _feeVault, "feeVault");
        assertEq(address(uint160(uint256(afterUpgrade[FEE_VAULT_SLOT]))), _feeVault, "feeVault slot");
        assertEq(afterUpgrade[DEPRECATED_COUNTERPART_SLOT], DEPRECATED_COUNTERPART_VALUE, "__counterpart");
        assertEq(afterUpgrade[DEPRECATED_RATE_LIMITER_SLOT], DEPRECATED_RATE_LIMITER_VALUE, "__rateLimiter");
        // L2ScrollMessenger.
        assertEq(
            upgraded.messageSendTimestamp(LEGACY_MESSAGE_HASH),
            LEGACY_SEND_TIMESTAMP,
            "messageSendTimestamp from before the upgrade"
        );
        assertEq(upgraded.messageSendTimestamp(sentHash), 0, "messageSendTimestamp is no longer written");
        assertTrue(upgraded.isL1MessageExecuted(executedHash), "isL1MessageExecuted");
        assertEq(afterUpgrade[USED_SLOT], USED_0_VALUE, "__used[0]");
        assertEq(afterUpgrade[USED_SLOT + 1], USED_1_VALUE, "__used[1]");

        // The immutables are reinstalled with the same bindings, and the queue the
        // messenger appends to is untouched by the upgrade.
        assertEq(upgraded.MOAT(), address(_moat), "MOAT");
        assertEq(upgraded.messageQueue(), address(_queue), "messageQueue");
        assertEq(upgraded.counterpart(), _l1Counterpart, "counterpart");
        assertEq(_queue.nextMessageIndex(), queueIndexBefore, "queue index");
        assertEq(_queue.messageRoot(), rootBefore, "queue root");
    }

    /// @dev The two mappings keep entries written through either implementation, so a
    ///      pre-upgrade and a post-upgrade entry must coexist under the same base slots.
    function test_Upgrade_MappingSlotsStayTheSame() external {
        bytes32 executedBefore = _relayDeposit(address(0xdef), 1);

        L2DogeOsMessenger upgraded = _upgradeToFresh();

        bytes32 executedAfter = _relayDeposit(address(0xfeed), 2);
        assertTrue(upgraded.isL1MessageExecuted(executedBefore), "entry written before the upgrade");
        assertTrue(upgraded.isL1MessageExecuted(executedAfter), "entry written after the upgrade");
        assertEq(
            vm.load(address(_proxy), keccak256(abi.encode(executedAfter, IS_L1_MESSAGE_EXECUTED_SLOT))),
            bytes32(uint256(1)),
            "isL1MessageExecuted still keyed on its pinned slot"
        );
        // Read back through the getter what `setUp` wrote at the pinned slot directly.
        assertEq(
            upgraded.messageSendTimestamp(LEGACY_MESSAGE_HASH),
            LEGACY_SEND_TIMESTAMP,
            "messageSendTimestamp still keyed on its pinned slot"
        );
    }

    function test_Upgrade_AdminAndSendPathsWork() external {
        vm.prank(_owner);
        _messenger.setPause(true);

        L2DogeOsMessenger upgraded = _upgradeToFresh();

        // Admin path: only the owner may unpause, and only the owner may repoint the vault.
        vm.prank(_user);
        vm.expectRevert("Ownable: caller is not the owner");
        upgraded.setPause(false);
        vm.prank(_owner);
        upgraded.setPause(false);
        assertFalse(upgraded.paused(), "unpaused by the owner");

        address newVault = address(0xfa18);
        vm.prank(_owner);
        upgraded.updateFeeVault(newVault);
        assertEq(upgraded.feeVault(), newVault, "fee vault repointed");

        // Send path: a withdrawal through the Moat appends to the queue.
        address target = address(0x1111);
        uint256 nonce = _queue.nextMessageIndex();
        vm.deal(_user, WITHDRAWAL);
        vm.expectEmit(true, true, true, true);
        emit IScrollMessenger.SentMessage(
            address(_moat),
            target,
            WITHDRAWAL,
            nonce,
            0,
            WithdrawalEnvelope.encode(false)
        );
        vm.prank(_user);
        _moat.withdrawToP2PKH{value: WITHDRAWAL}(target);
        bytes32 sentHash = _messageHash(address(_moat), target, WITHDRAWAL, nonce, WithdrawalEnvelope.encode(false));
        assertEq(_queue.nextMessageIndex(), nonce + 1, "queue index advanced");
        assertEq(upgraded.messageSendTimestamp(sentHash), 0, "the send still does not write the timestamp");

        // Relay path: a deposit still reaches its recipient through the Moat.
        address recipient = address(0xdef);
        bytes32 relayHash = _relayDeposit(recipient, 9);
        assertTrue(upgraded.isL1MessageExecuted(relayHash), "deposit relayed after the upgrade");
        assertEq(recipient.balance, DEPOSIT, "recipient credited after the upgrade");

        // A sender other than the Moat still cannot send an L2 -> L1 message.
        vm.deal(_user, WITHDRAWAL);
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(L2DogeOsMessenger.ErrorSenderNotMoat.selector, _user, address(_moat)));
        upgraded.sendMessage{value: WITHDRAWAL}(target, WITHDRAWAL, WithdrawalEnvelope.encode(false), 0);
    }

    function test_Upgrade_InitializeCannotRerun() external {
        L2DogeOsMessenger upgraded = _upgradeToFresh();

        vm.expectRevert("Initializable: contract is already initialized");
        upgraded.initialize(_l1Counterpart);

        vm.prank(_owner);
        vm.expectRevert("Initializable: contract is already initialized");
        upgraded.initialize(_l1Counterpart);
    }

    /// @dev The constructor disables initializers, so an implementation can only ever be
    ///      initialized behind a proxy. An owner taken on the implementation itself could
    ///      otherwise pause it or repoint its fee vault.
    function test_ImplementationCannotBeInitialized() external {
        L2DogeOsMessenger implementation = _freshImplementation();

        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(_l1Counterpart);

        assertEq(implementation.owner(), address(0), "the implementation must have no owner");
    }
}
