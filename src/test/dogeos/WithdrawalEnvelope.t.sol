// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

import {WithdrawalEnvelope} from "../../dogeos/WithdrawalEnvelope.sol";
import {ReferenceWithdrawalEnvelope} from "./reference/ReferenceWithdrawalEnvelope.sol";

/// @dev Exposes both implementations with memory inputs, as the messenger uses them.
contract WithdrawalEnvelopeHarness {
    function encodeNew(bool isP2SH) external pure returns (bytes memory) {
        return WithdrawalEnvelope.encode(isP2SH);
    }

    function encodeReference(bool isP2SH) external pure returns (bytes memory) {
        return ReferenceWithdrawalEnvelope.encode(isP2SH);
    }

    function isValidNew(bytes memory message) external pure returns (bool) {
        return WithdrawalEnvelope.isValid(message);
    }

    function isValidReference(bytes memory message) external pure returns (bool) {
        return ReferenceWithdrawalEnvelope.isValid(message);
    }
}

/// @notice The single-word envelope encoder/validator must behave exactly like the pinned
///         byte-by-byte reference implementation.
contract WithdrawalEnvelopeTest is Test {
    WithdrawalEnvelopeHarness internal _h;

    function setUp() public {
        _h = new WithdrawalEnvelopeHarness();
    }

    function test_EncodeMatchesReference() external view {
        assertEq(_h.encodeNew(false), _h.encodeReference(false));
        assertEq(_h.encodeNew(true), _h.encodeReference(true));
        assertEq(_h.encodeNew(false), hex"0100");
        assertEq(_h.encodeNew(true), hex"0101");
    }

    function test_IsValidMatchesReference_AllTwoByteMessages() external view {
        for (uint256 i = 0; i < 0x10000; i += 1) {
            bytes memory message = abi.encodePacked(bytes2(uint16(i)));
            assertEq(_h.isValidNew(message), _h.isValidReference(message), vm.toString(message));
        }
    }

    /// @dev Valid envelopes followed by more bytes, or cut short, must be rejected by both.
    function test_IsValidMatchesReference_OtherLengths() external view {
        bytes[6] memory messages = [
            new bytes(0),
            bytes(hex"01"),
            bytes(hex"010000"),
            bytes(hex"010100"),
            bytes(hex"0100ff"),
            bytes(hex"01010101010101010101010101010101010101010101010101010101010101010101")
        ];
        for (uint256 i = 0; i < messages.length; i += 1) {
            assertEq(_h.isValidNew(messages[i]), _h.isValidReference(messages[i]));
            assertFalse(_h.isValidNew(messages[i]));
        }
    }

    function testFuzz_IsValidMatchesReference(bytes memory message) external view {
        assertEq(_h.isValidNew(message), _h.isValidReference(message));
    }

    /// @dev A two-byte message whose memory word has non-zero bytes right after it must still
    ///      be judged only on its two bytes. Called in-process (not through the harness) so the
    ///      dirty memory survives: an external call would re-encode the message and drop it.
    function testFuzz_IsValidIgnoresDirtyMemoryPastTheEnd(
        bytes1 a,
        bytes1 b,
        bytes30 tail
    ) external pure {
        vm.assume(tail != bytes30(0));
        bytes memory message = abi.encodePacked(a, b, tail);
        assembly {
            mstore(message, 2) // shrink to two bytes; the tail stays in memory after them
        }
        assertEq(WithdrawalEnvelope.isValid(message), ReferenceWithdrawalEnvelope.isValid(message));
    }

    function test_IsValidIgnoresDirtyMemoryPastTheEnd_ValidEnvelope() external pure {
        bytes memory message = abi.encodePacked(bytes2(0x0101), bytes30(type(uint240).max));
        assembly {
            mstore(message, 2)
        }
        assertTrue(WithdrawalEnvelope.isValid(message));
    }
}
