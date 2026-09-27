// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

// REFERENCE IMPLEMENTATION (test-only). Do not modify.
//
// Verbatim copy of src/dogeos/WithdrawalEnvelope.sol at commit 28f6ca9 (the
// byte-by-byte envelope encoder/validator); only the library name differs. It is
// the equivalence oracle for the single-word implementation: the tests require
// both to agree on every input. To confirm the copy is verbatim:
//   diff <(git show 28f6ca9:src/dogeos/WithdrawalEnvelope.sol) src/test/dogeos/reference/ReferenceWithdrawalEnvelope.sol
//
// Files under src/test/**/reference/ hold such pinned implementations. They are
// compiled only by the test suite and never deployed.

/**
 * @title WithdrawalEnvelope
 * @notice Canonical encoding of the 2-byte L2->L1 withdrawal message envelope, shared by
 *         the Moat (producer) and the L2DogeOsMessenger (enforcer).
 * @dev There is exactly ONE valid message representation per Dogecoin recipient type:
 *
 *           P2PKH: 0x0100    P2SH: 0x0101
 *
 *      so the full message bytes are deterministically reconstructable from the Dogecoin
 *      address used in the withdrawal (the address prefix selects the flag). Legacy
 *      pre-v0.3.0 blank messages are NOT valid: the messenger rejects them, so downstream
 *      consumers never face two possible representations for the same recipient.
 */
library ReferenceWithdrawalEnvelope {
    /// @notice Envelope version byte.
    uint8 internal constant VERSION = 1;

    /// @notice Flags byte for a P2PKH (pubkey hash160) recipient.
    bytes1 internal constant FLAG_P2PKH = 0x00;

    /// @notice Flags byte for a P2SH (script hash160) recipient.
    bytes1 internal constant FLAG_P2SH = 0x01;

    /**
     * @notice Encode the withdrawal envelope.
     * @param _isP2SH True for P2SH, false for P2PKH.
     * @return envelope The 2-byte envelope (version, flags).
     */
    function encode(bool _isP2SH) internal pure returns (bytes memory envelope) {
        envelope = new bytes(2);
        envelope[0] = bytes1(VERSION);
        envelope[1] = _isP2SH ? FLAG_P2SH : FLAG_P2PKH;
    }

    /**
     * @notice Check whether a message is exactly a valid v1 withdrawal envelope.
     * @dev Strict: length 2, version byte 1, flags byte P2PKH or P2SH. A future envelope
     *      version requires upgrading the messenger's validation alongside the Moat.
     * @param _message The L2->L1 message bytes.
     * @return True iff the message is a valid v1 envelope.
     */
    function isValid(bytes memory _message) internal pure returns (bool) {
        return
            _message.length == 2 &&
            _message[0] == bytes1(VERSION) &&
            (_message[1] == FLAG_P2PKH || _message[1] == FLAG_P2SH);
    }
}
