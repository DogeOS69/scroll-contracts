// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test, stdError} from "forge-std/Test.sol";

import {L2MessageQueue} from "../L2/predeploys/L2MessageQueue.sol";
import {ReferenceL2MessageQueue} from "./reference/ReferenceL2MessageQueue.sol";

/// @notice Equivalence of the optimized L2MessageQueue (one `branches` write per append,
///         zero hashes derived in memory) with the original Scroll implementation pinned in
///         src/test/reference/. The withdraw root (slot 0) and nextMessageIndex (slot 1) are
///         what the node, the prover and the off-chain services read, so they must match on
///         every append; `branches` must match on the live frontier (the set bits of
///         nextMessageIndex), the only entries a later append reads.
contract L2MessageQueueEquivalenceTest is Test {
    event AppendMessage(uint256 index, bytes32 messageHash);

    // L2MessageQueue storage layout: messageRoot 0, nextMessageIndex 1, zeroHashes 2..41,
    // branches 42..81, owner 82, messenger 83.
    uint256 private constant NEXT_INDEX_SLOT = 1;
    uint256 private constant BRANCHES_SLOT = 42;
    uint256 private constant MESSENGER_SLOT = 83;
    uint256 private constant MAX_TREE_HEIGHT = 40;
    /// @dev Number of leaves the tree holds: indices 0 .. 2^39 - 1.
    uint256 private constant CAPACITY = 1 << (MAX_TREE_HEIGHT - 1);

    L2MessageQueue internal queue;
    ReferenceL2MessageQueue internal ref;

    function setUp() public {
        queue = new L2MessageQueue(address(this));
        queue.initialize(address(this));
        ref = new ReferenceL2MessageQueue(address(this));
        ref.initialize(address(this));
    }

    /// @dev Roots, indices and the live frontier of `_a` and `_b` agree.
    function _assertEquivalent(address _a, address _b) internal view {
        uint256 next = L2MessageQueue(_a).nextMessageIndex();
        assertEq(next, L2MessageQueue(_b).nextMessageIndex(), "nextMessageIndex");
        assertEq(L2MessageQueue(_a).messageRoot(), L2MessageQueue(_b).messageRoot(), "messageRoot");
        for (uint256 h = 0; h < MAX_TREE_HEIGHT; h++) {
            if ((next >> h) & 1 == 1) {
                assertEq(L2MessageQueue(_a).branches(h), L2MessageQueue(_b).branches(h), "live branch");
            }
        }
    }

    /// @dev Appends the same leaf to both queues and checks results and state agree.
    function _appendBoth(
        address _a,
        address _b,
        bytes32 _leaf
    ) internal {
        uint256 index = L2MessageQueue(_a).nextMessageIndex();
        vm.expectEmit(address(_a));
        emit AppendMessage(index, _leaf);
        bytes32 rootA = L2MessageQueue(_a).appendMessage(_leaf);
        bytes32 rootB = L2MessageQueue(_b).appendMessage(_leaf);
        assertEq(rootA, rootB, "returned root");
        assertEq(rootA, L2MessageQueue(_a).messageRoot(), "returned root is stored");
        _assertEquivalent(_a, _b);
    }

    /// After `initialize` every slot (zeroHashes included) is identical to the original.
    function testInitialize_StorageUnchanged() external view {
        for (uint256 slot = 0; slot <= MESSENGER_SLOT; slot++) {
            assertEq(vm.load(address(queue), bytes32(slot)), vm.load(address(ref), bytes32(slot)), "slot");
        }
    }

    /// Every root from an empty tree for the first 1,100 leaves (tree heights 0..11).
    function testEquivalence_FromEmpty() external {
        for (uint256 i = 0; i < 1100; i++) {
            _appendBoth(address(queue), address(ref), keccak256(abi.encode("leaf", i)));
        }
    }

    /// @dev Puts both queues at leaf index `_start` with the same arbitrary live frontier
    /// (the `branches` at the set bits of `_start`). Every non-live `branches` slot gets
    /// different junk in each queue, so a read of a non-live slot would show up as a root
    /// mismatch.
    function _setArbitraryFrontier(uint256 _start, bytes32 _seed) internal {
        for (uint256 h = 0; h < MAX_TREE_HEIGHT; h++) {
            bool isLive = (_start >> h) & 1 == 1;
            bytes32 live = keccak256(abi.encode(_seed, h));
            vm.store(
                address(ref),
                bytes32(BRANCHES_SLOT + h),
                isLive ? live : keccak256(abi.encode("ref junk", _seed, h))
            );
            vm.store(
                address(queue),
                bytes32(BRANCHES_SLOT + h),
                isLive ? live : keccak256(abi.encode("junk", _seed, h))
            );
        }
        vm.store(address(ref), bytes32(NEXT_INDEX_SLOT), bytes32(_start));
        vm.store(address(queue), bytes32(NEXT_INDEX_SLOT), bytes32(_start));
    }

    /// Starting at an arbitrary index with an arbitrary (identical) live frontier and junk in
    /// every non-live slot: neither implementation reads a non-live slot before overwriting it,
    /// so both produce the same roots.
    function testFuzzEquivalence_FromArbitraryFrontier(
        uint64 _start,
        bytes32 _seed,
        uint8 _count
    ) external {
        uint256 start = bound(uint256(_start), 1, CAPACITY - 300);
        _setArbitraryFrontier(start, _seed);

        uint256 n = bound(uint256(_count), 1, 256);
        for (uint256 i = 0; i < n; i++) {
            _appendBoth(address(queue), address(ref), keccak256(abi.encode(_seed, "leaf", i)));
        }
    }

    /// Models the testnet hardfork: a queue that ran the original code for `_before` appends
    /// has its runtime code replaced by the optimized code in place (storage untouched) and
    /// keeps producing the same roots as a queue that stays on the original code.
    function testFuzzEquivalence_CodeReplacedInPlace(uint16 _before, uint8 _after) external {
        ReferenceL2MessageQueue upgraded = new ReferenceL2MessageQueue(address(this));
        upgraded.initialize(address(this));

        uint256 before = bound(uint256(_before), 0, 600);
        for (uint256 i = 0; i < before; i++) {
            bytes32 leaf = keccak256(abi.encode("pre", i));
            assertEq(upgraded.appendMessage(leaf), ref.appendMessage(leaf));
        }

        vm.etch(address(upgraded), address(queue).code);

        uint256 afterCount = bound(uint256(_after), 1, 200);
        for (uint256 i = 0; i < afterCount; i++) {
            _appendBoth(address(upgraded), address(ref), keccak256(abi.encode("post", i)));
        }
    }

    /// @dev Both queues are full (the leaf at index CAPACITY - 1 was the last accepted): the
    /// next append reverts in both. The original code has no explicit check; appending leaf
    /// CAPACITY walks its loop to height 40 and indexes `branches[40]`, an out-of-bounds
    /// panic (0x32). The optimized code rejects it up front with "merkle tree is full".
    function _assertBothFull() internal {
        assertEq(queue.nextMessageIndex(), CAPACITY);
        assertEq(ref.nextMessageIndex(), CAPACITY);
        vm.expectRevert(stdError.indexOOBError);
        ref.appendMessage(bytes32(uint256(2)));
        vm.expectRevert("merkle tree is full");
        queue.appendMessage(bytes32(uint256(2)));
    }

    /// The capacity is unchanged: leaf index 2^39 - 1 is the last one accepted.
    function testCapacityLimitUnchanged() external {
        _setArbitraryFrontier(CAPACITY - 1, bytes32(0));
        _appendBoth(address(queue), address(ref), bytes32(uint256(1)));
        _assertBothFull();
    }

    /// From an arbitrary valid frontier just below the capacity, every append up to and
    /// including the last allowed leaf (index 2^39 - 1) matches the original, and the next
    /// append reverts in both implementations.
    function testFuzzEquivalence_UpToCapacity(bytes32 _seed, uint8 _count) external {
        uint256 n = bound(uint256(_count), 1, 256);
        _setArbitraryFrontier(CAPACITY - n, _seed);
        for (uint256 i = 0; i < n; i++) {
            _appendBoth(address(queue), address(ref), keccak256(abi.encode(_seed, "last", i)));
        }
        _assertBothFull();
    }

    function testAppendMessage_RevertWhenNotMessenger() external {
        vm.startPrank(address(0xdead));
        vm.expectRevert("only messenger");
        queue.appendMessage(bytes32(uint256(1)));
        vm.expectRevert("only messenger");
        ref.appendMessage(bytes32(uint256(1)));
        vm.stopPrank();
    }

    /// Before `initialize` the messenger is unset, so no append can happen (the original's
    /// separate "call before initialization" check on zeroHashes[1] is subsumed).
    function testAppendMessage_RevertBeforeInitialize() external {
        L2MessageQueue fresh = new L2MessageQueue(address(this));
        vm.expectRevert("only messenger");
        fresh.appendMessage(bytes32(uint256(1)));
    }
}
