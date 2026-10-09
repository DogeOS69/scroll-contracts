// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenerateGenesis} from "../../scripts/deterministic/GenerateGenesis.s.sol";
import {BlockHashHistory} from "../libraries/constants/BlockHashHistory.sol";

contract BlockHashHistoryGenesisHarness is GenerateGenesis {
    function install() external {
        setBlockHashHistory();
    }
}

/// @dev Tests the actual genesis runtime. System calls here model client block
/// processing; client integration must additionally verify ordering/gas accounting.
contract BlockHashHistoryTest is Test {
    address private constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    address private constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint256 private constant WINDOW = 8191;

    function setUp() public {
        new BlockHashHistoryGenesisHarness().install();
    }

    function testCanonicalAccount() public view {
        assertEq(BlockHashHistory.ADDRESS, HISTORY);
        assertEq(HISTORY.code.length, 83);
        assertEq(HISTORY.codehash, 0x6e49e66782037c0555897870e29fa5e552daf4719552131a0abce779daec0a5d);
        assertEq(vm.getNonce(HISTORY), 1);
        assertEq(HISTORY.balance, 0);
        for (uint256 i; i < WINDOW; ++i) {
            assertEq(vm.load(HISTORY, bytes32(i)), bytes32(0));
        }
    }

    function testBlockOneRecordsGenesisHash() public {
        bytes32 genesisHash = keccak256("L2 genesis");
        writeParent(1, genesisHash);
        assertEq(vm.load(HISTORY, bytes32(0)), genesisHash);
        assertEq(readHistory(0), genesisHash);
        bytes32 nextHash = keccak256("L2 block 1");
        writeParent(2, nextHash);
        assertEq(readHistory(0), genesisHash);
        assertEq(readHistory(1), nextHash);
    }

    function testFuzzRejectMalformedCalldata(bytes memory input) public {
        vm.assume(input.length != 32);
        vm.roll(100);
        (bool success, bytes memory result) = HISTORY.staticcall(input);
        assertFalse(success);
        assertEq(result.length, 0);
    }

    function testRejectCurrentFutureAndExpiredQueries() public {
        writeParent(WINDOW + 1, keccak256("parent"));
        assertReverts(0);
        assertReverts(WINDOW + 1);
        assertReverts(WINDOW + 2);
        assertReverts(type(uint256).max);
        // Exactly WINDOW blocks old is valid, even if not yet populated.
        assertEq(readHistory(1), bytes32(0));
        assertEq(readHistory(WINDOW), keccak256("parent"));
    }

    function testRingBufferRollover() public {
        for (uint256 i = 1; i <= WINDOW; ++i) {
            writeParent(i, bytes32(i));
        }
        assertEq(readHistory(0), bytes32(uint256(1)));
        writeParent(WINDOW + 1, bytes32(uint256(WINDOW + 1)));
        assertReverts(0);
        assertEq(readHistory(1), bytes32(uint256(2)));
        assertEq(readHistory(WINDOW), bytes32(uint256(WINDOW + 1)));
        assertEq(vm.load(HISTORY, bytes32(0)), bytes32(uint256(WINDOW + 1)));
    }

    function testLaterActivationDoesNotBackfill() public {
        // The first system call at activation block 32 records only block 31.
        writeParent(32, keccak256("L2 block 31"));
        for (uint256 i; i < 31; ++i) {
            assertEq(readHistory(i), bytes32(0));
        }
        assertEq(readHistory(31), keccak256("L2 block 31"));
        writeParent(33, keccak256("L2 block 32"));
        assertEq(readHistory(30), bytes32(0));
        assertEq(readHistory(31), keccak256("L2 block 31"));
        assertEq(readHistory(32), keccak256("L2 block 32"));
    }

    function testFuzzOrdinaryCallersCannotWrite(address caller) public {
        vm.assume(caller != SYSTEM);
        bytes32 parentHash = keccak256("parent");
        writeParent(2, parentHash);
        // Valid calldata is interpreted as a read, even through CALL.
        vm.prank(caller);
        (bool success, bytes memory result) = HISTORY.call(abi.encode(uint256(1)));
        assertTrue(success);
        assertEq(abi.decode(result, (bytes32)), parentHash);
        vm.prank(caller);
        (success, ) = HISTORY.call(abi.encode(parentHash));
        assertFalse(success);
        assertEq(vm.load(HISTORY, bytes32(uint256(1))), parentHash);
        assertEq(vm.load(HISTORY, bytes32(0)), bytes32(0));
    }

    function testHistoryExtendsBeyondBlockhashWindow() public {
        writeParent(1, keccak256("genesis"));
        vm.roll(258);
        assertEq(readHistory(0), keccak256("genesis"));
        assertEq(blockhash(0), bytes32(0));
    }

    function writeParent(uint256 number, bytes32 parentHash) private {
        vm.roll(number);
        vm.prank(SYSTEM);
        (bool success, bytes memory result) = HISTORY.call(abi.encode(parentHash));
        assertTrue(success);
        assertEq(result.length, 0);
    }

    function readHistory(uint256 number) private view returns (bytes32) {
        (bool success, bytes memory result) = HISTORY.staticcall(abi.encode(number));
        assertTrue(success);
        assertEq(result.length, 32);
        return abi.decode(result, (bytes32));
    }

    function assertReverts(uint256 number) private view {
        (bool success, bytes memory result) = HISTORY.staticcall(abi.encode(number));
        assertFalse(success);
        assertEq(result.length, 0);
    }
}
