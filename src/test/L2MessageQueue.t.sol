// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";

import {L2MessageQueue} from "../L2/predeploys/L2MessageQueue.sol";

contract L2MessageQueueTest is DSTestPlus {
    L2MessageQueue queue;

    function setUp() public {
        queue = new L2MessageQueue(address(this));
        queue.initialize(address(this));
    }

    function testConstructor() external {
        assertEq(queue.messenger(), address(this));
        assertEq(queue.nextMessageIndex(), 0);
    }

    function testPassMessageFailed() external {
        // not messenger
        hevm.startPrank(address(0));
        hevm.expectRevert("only messenger");
        queue.appendMessage(bytes32(0));
        hevm.stopPrank();
    }

    function testPassMessageOnceSuccess(bytes32 _message) external {
        queue.appendMessage(_message);
        assertEq(queue.nextMessageIndex(), 1);
        assertEq(queue.messageRoot(), keccak256(abi.encodePacked(bytes32(0), _message)));
    }

    function testPassMessageSuccess() external {
        queue.appendMessage(bytes32(uint256(1)));
        assertEq(queue.nextMessageIndex(), 1);
        assertEq(queue.messageRoot(), 0xa6eef7e35abe7026729641147f7915573c7e97b47efa546f5f6e3230263bcb49);
        queue.appendMessage(bytes32(uint256(2)));
        assertEq(queue.nextMessageIndex(), 2);
        assertEq(queue.messageRoot(), 0x6b7cf3666cb877c85468a54a4b1507c9e2cdc58f77e1c2709d37b70cc337c4e9);
        queue.appendMessage(bytes32(uint256(3)));
        assertEq(queue.nextMessageIndex(), 3);
        assertEq(queue.messageRoot(), 0xa732dab0e90325f680f60605209acab91df17a2a018eecc4b4bfc091b76a8d7f);
        queue.appendMessage(bytes32(uint256(4)));
        assertEq(queue.nextMessageIndex(), 4);
        assertEq(queue.messageRoot(), 0x2a2c1a9f9c9fbebbf2dce2f8e9b96d5bcf0374b203bb2f7330def1cdbc47eb8c);
    }

    event AppendMessage(uint256 index, bytes32 messageHash);

    function testCheckpointStorageLayout() external {
        // Preserve a nonzero checkpoint and the inherited owner/messenger slots on upgrade.
        bytes32 seed = bytes32(uint256(42));
        hevm.store(address(queue), bytes32(uint256(0)), seed);
        hevm.store(address(queue), bytes32(uint256(1)), bytes32(uint256(7)));
        assertEq(address(uint160(uint256(hevm.load(address(queue), bytes32(uint256(82)))))), address(this));
        assertEq(address(uint160(uint256(hevm.load(address(queue), bytes32(uint256(83)))))), address(this));
        queue.appendMessage(bytes32(uint256(8)));
        assertEq(queue.nextMessageIndex(), 8);
        assertEq(queue.messageRoot(), keccak256(abi.encodePacked(seed, bytes32(uint256(8)))));
    }

    function testCodeReplacementKeepsLegacyStorage() external {
        address owner = address(0xA11CE);
        address messenger = address(0xB0B);
        L2MessageQueue legacy = new L2MessageQueue(owner);
        hevm.prank(owner);
        legacy.initialize(messenger);

        // Legacy tree state: a checkpoint root/count plus zeroHashes/branches in slots 2..81.
        bytes32 seed = keccak256("legacy root");
        hevm.store(address(legacy), bytes32(uint256(0)), seed);
        hevm.store(address(legacy), bytes32(uint256(1)), bytes32(uint256(680_000)));
        for (uint256 slot = 2; slot < 82; slot++) {
            hevm.store(address(legacy), bytes32(slot), keccak256(abi.encode(slot)));
        }

        // Replace the runtime in place, as a code-replacement fork would.
        hevm.etch(address(legacy), address(new L2MessageQueue(address(1))).code);

        assertEq(legacy.owner(), owner);
        assertEq(legacy.messenger(), messenger);
        assertEq(legacy.messageRoot(), seed);
        assertEq(legacy.nextMessageIndex(), 680_000);

        hevm.prank(owner);
        hevm.expectRevert("only messenger");
        legacy.appendMessage(bytes32(uint256(1)));

        bytes32 leaf = bytes32(uint256(0xbeef));
        hevm.expectEmit(false, false, false, true);
        emit AppendMessage(680_000, leaf);
        hevm.prank(messenger);
        bytes32 root = legacy.appendMessage(leaf);
        assertEq(root, keccak256(abi.encodePacked(seed, leaf)));
        assertEq(legacy.messageRoot(), root);
        assertEq(legacy.nextMessageIndex(), 680_001);
        for (uint256 slot = 2; slot < 82; slot++) {
            assertEq(hevm.load(address(legacy), bytes32(slot)), keccak256(abi.encode(slot)));
        }
    }

    function testCountStopsAtUint64Max() external {
        hevm.store(address(queue), bytes32(uint256(1)), bytes32(uint256(type(uint64).max - 1)));
        queue.appendMessage(bytes32(uint256(9)));
        assertEq(queue.nextMessageIndex(), type(uint64).max);
        hevm.expectRevert("message index overflow");
        queue.appendMessage(bytes32(uint256(10)));
    }
}
