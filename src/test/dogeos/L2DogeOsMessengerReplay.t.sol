// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {L2DogeOsMessenger} from "../../dogeos/L2DogeOsMessenger.sol";
import {Moat} from "../../dogeos/Moat.sol";
import {L2MessageQueue} from "../../L2/predeploys/L2MessageQueue.sol";
import {AddressAliasHelper} from "../../libraries/common/AddressAliasHelper.sol";
import {IScrollMessenger} from "../../libraries/IScrollMessenger.sol";
import {MoatTestBase} from "./MoatTestBase.t.sol";

/// @dev Deposit target that can be switched to reject value, to make a relay fail and then retry it.
contract ToggleReceiver {
    bool public reject;

    function setReject(bool _reject) external {
        reject = _reject;
    }

    receive() external payable {
        require(!reject, "rejected");
    }
}

/// @notice Replay protection keyed by L1 message nonce (bitmap), plus the legacy per-hash mapping
///         for messengers upgraded in place (LEGACY_REPLAY_CHECK).
contract L2DogeOsMessengerReplayTest is MoatTestBase {
    using stdStorage for StdStorage;

    address internal constant L1_MESSENGER = address(0x1111);
    address internal constant L1_SENDER = address(0xabc);
    uint256 internal constant VALUE = 1 ether;

    L2DogeOsMessenger internal _messenger;
    Moat internal _moat;
    ToggleReceiver internal _target;

    function setUp() public {
        L2MessageQueue queue = new L2MessageQueue(address(this));
        (ProxyAdmin admin, address moatProxy) = _deployEmptyProxy();
        // An upgraded messenger: deposits may have been relayed under the old per-hash mapping.
        _messenger = new L2DogeOsMessenger(L1_MESSENGER, address(queue), moatProxy, true);
        _moat = _installMoat(
            admin,
            moatProxy,
            address(_messenger),
            MoatConfig({
                owner: address(this),
                feeRecipient: address(0xfee),
                withdrawalFee: 0,
                depositFee: 0,
                minWithdrawal: 0.01 ether,
                feeExemptCaller: address(0)
            })
        );
        vm.deal(address(_messenger), 1_000 ether);
        _target = new ToggleReceiver();
    }

    function _deposit(uint256 depositId) internal view returns (bytes memory) {
        return abi.encodeCall(Moat.handleL1Message, (address(_target), bytes32(depositId)));
    }

    function _hash(uint256 nonce, bytes memory message) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodeWithSignature(
                    "relayMessage(address,address,uint256,uint256,bytes)",
                    L1_SENDER,
                    address(_moat),
                    VALUE,
                    nonce,
                    message
                )
            );
    }

    function _relay(uint256 nonce, bytes memory message) internal {
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        _messenger.relayMessage(L1_SENDER, address(_moat), VALUE, nonce, message);
    }

    function _expectReplayRevert(uint256 nonce, bytes memory message) internal {
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        vm.expectRevert("Message was already successfully executed");
        _messenger.relayMessage(L1_SENDER, address(_moat), VALUE, nonce, message);
    }

    /// @dev Records a success in the per-hash mapping, as the pre-upgrade implementation did.
    function _markLegacyExecuted(bytes32 hash) internal {
        stdstore.target(address(_messenger)).sig("isL1MessageExecuted(bytes32)").with_key(hash).checked_write(true);
    }

    // --- Bitmap --- //

    function test_SuccessSetsNonceBitAndNotTheHashMapping() external {
        uint256 nonce = 1_000 + 500;
        bytes memory message = _deposit(1);

        vm.expectEmit(true, false, false, false, address(_messenger));
        emit IScrollMessenger.RelayedMessage(_hash(nonce, message));
        _relay(nonce, message);

        assertTrue(_messenger.isL1MessageNonceExecuted(nonce), "nonce bit set");
        assertFalse(_messenger.isL1MessageExecuted(_hash(nonce, message)), "per-hash mapping frozen");
        assertEq(address(_target).balance, VALUE, "deposit credited");
    }

    function test_ReplayOfSameMessageReverts() external {
        bytes memory message = _deposit(2);
        _relay(1_000 + 7, message);
        _expectReplayRevert(1_000 + 7, message);
    }

    /// @dev Stricter than the per-hash mapping: a different message cannot reuse a relayed nonce.
    function test_DifferentMessageReusingNonceReverts() external {
        _relay(1_000 + 8, _deposit(3));
        _expectReplayRevert(1_000 + 8, _deposit(4));
    }

    function test_FailedRelayStaysRetryable() external {
        uint256 nonce = 1_000 + 9;
        bytes memory message = _deposit(5);

        _target.setReject(true);
        vm.expectEmit(true, false, false, false, address(_messenger));
        emit IScrollMessenger.FailedRelayedMessage(_hash(nonce, message));
        _relay(nonce, message);
        assertFalse(_messenger.isL1MessageNonceExecuted(nonce), "failed relay not recorded");

        _target.setReject(false);
        _relay(nonce, message);
        assertTrue(_messenger.isL1MessageNonceExecuted(nonce), "retry recorded");
        assertEq(address(_target).balance, VALUE, "credited once");
        _expectReplayRevert(nonce, message);
    }

    function test_NoncesAcrossBitmapWordBoundariesAreIndependent() external {
        uint256[6] memory nonces = [uint256(1_279), 1_280, 1_535, 1_536, type(uint64).max, type(uint256).max];
        for (uint256 i = 0; i < nonces.length; i++) {
            for (uint256 j = 0; j < nonces.length; j++) {
                assertEq(_messenger.isL1MessageNonceExecuted(nonces[j]), j < i, "only earlier nonces set");
            }
            _relay(nonces[i], _deposit(100 + i));
        }
    }

    function testFuzz_ReplayRejectedForAnyNonce(uint256 nonce) external {
        bytes memory message = _deposit(6);
        _relay(nonce, message);
        assertTrue(_messenger.isL1MessageNonceExecuted(nonce));
        _expectReplayRevert(nonce, message);
    }

    // --- Legacy per-hash mapping (LEGACY_REPLAY_CHECK) --- //

    function testFuzz_LegacySuccessIsRejected(uint256 nonce) external {
        bytes memory message = _deposit(7);
        _markLegacyExecuted(_hash(nonce, message));
        _expectReplayRevert(nonce, message);
        assertEq(address(_target).balance, 0, "not credited again");
    }

    /// @dev A message that was pending (not yet relayed) at the upgrade relays once afterwards.
    function test_PendingLegacyMessageRelaysOnce() external {
        bytes memory message = _deposit(9);
        _relay(10, message);
        assertTrue(_messenger.isL1MessageNonceExecuted(10));
        assertEq(address(_target).balance, VALUE);
        _expectReplayRevert(10, message);
    }

    /// @dev A legacy failure (not recorded in the old mapping) stays retryable.
    function test_LegacyFailureIsRetryable() external {
        bytes memory message = _deposit(10);
        _target.setReject(true);
        _relay(20, message);
        _target.setReject(false);
        _relay(20, message);
        assertTrue(_messenger.isL1MessageNonceExecuted(20));
    }

    /// @dev A fresh messenger (LEGACY_REPLAY_CHECK false) has no legacy records and skips the
    ///      old mapping entirely.
    function test_FreshMessengerDoesNotReadLegacyMapping() external {
        L2MessageQueue queue = new L2MessageQueue(address(this));
        (ProxyAdmin admin, address moatProxy) = _deployEmptyProxy();
        L2DogeOsMessenger fresh = new L2DogeOsMessenger(L1_MESSENGER, address(queue), moatProxy, false);
        Moat moat = _installMoat(
            admin,
            moatProxy,
            address(fresh),
            MoatConfig({
                owner: address(this),
                feeRecipient: address(0xfee),
                withdrawalFee: 0,
                depositFee: 0,
                minWithdrawal: 0.01 ether,
                feeExemptCaller: address(0)
            })
        );
        vm.deal(address(fresh), 10 ether);
        bytes memory message = abi.encodeCall(Moat.handleL1Message, (address(_target), bytes32(0)));
        bytes32 hash = keccak256(
            abi.encodeWithSignature(
                "relayMessage(address,address,uint256,uint256,bytes)",
                L1_SENDER,
                address(moat),
                VALUE,
                uint256(30),
                message
            )
        );
        stdstore.target(address(fresh)).sig("isL1MessageExecuted(bytes32)").with_key(hash).checked_write(true);

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(L1_MESSENGER));
        fresh.relayMessage(L1_SENDER, address(moat), VALUE, 30, message);
        assertTrue(fresh.isL1MessageNonceExecuted(30), "old mapping not consulted");
    }
}
