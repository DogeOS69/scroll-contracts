// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title DogeSig
 * @notice Library for verifying Dogecoin Core-compatible `signmessage` signatures and
 *         recovering the corresponding P2PKH key hash (HASH160 of the public key).
 * @dev Pure functions designed to be linked/inlined into contracts, not deployed separately.
 *
 *      The compatibility target is Dogecoin Core's `verifymessage` RPC: the message is
 *      serialized as `compactSize(len(magic)) || magic || compactSize(len(message)) || message`
 *      with magic "Dogecoin Signed Message:\n", double-SHA256 hashed, and the 65-byte compact
 *      signature (header || r || s) recovers a secp256k1 public key whose HASH160
 *      (ripemd160(sha256(serializedPubkey))) is compared to the address key hash.
 *
 *      Because EVM `ecrecover` returns only the Ethereum-style address (low 160 bits of
 *      keccak256 of the uncompressed public key), callers must supply the full public key
 *      (x, y) as a witness. The library validates the witness is on the secp256k1 curve and
 *      binds it to the signature via the ecrecover result before deriving the key hash.
 *
 *      Error policy:
 *      - Reverts on malformed input that is never signer-dependent: oversized message,
 *        header outside [27, 34], recovery id 2/3 (unsupported by EVM ecrecover; only
 *        occurs when r >= n, probability ~2^-128), or a public key witness not on the curve.
 *      - Returns false on verification failure that may be attacker-controlled: invalid
 *        signature values, witness not matching the signature, or key-hash mismatch.
 *
 *      Malleability: matching Dogecoin Core semantics, no low-s check is enforced — for any
 *      valid signature (s, recId), the twin (n - s, recId ^ 1) also verifies. Consumers MUST
 *      NOT use signature bytes as replay-protection keys; use nonces or typed intent hashes.
 *
 *      RIPEMD-160 is computed via the precompile at address 0x03 (isolated in `_hash160`).
 *      Confirm prover support for this precompile before relying on it in production blocks.
 */
library DogeSig {
    // --- Constants --- //

    /// @dev Dogecoin Core message magic ("strMessageMagic"). 25 bytes, so its CompactSize
    ///      length prefix is the single byte 0x19.
    bytes internal constant MESSAGE_MAGIC = "Dogecoin Signed Message:\n";

    /// @dev Maximum raw message length accepted by {dogecoinMessageHash}.
    uint256 internal constant MAX_MESSAGE_LENGTH = 1024;

    /// @dev secp256k1 field prime p.
    uint256 internal constant SECP256K1_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // --- Errors --- //

    error ErrorMessageTooLong(uint256 length, uint256 maxLength);
    error ErrorInvalidSignatureHeader(uint8 header);
    error ErrorUnsupportedRecoveryId(uint8 recId);
    error ErrorInvalidPublicKey(bytes32 x, bytes32 y);

    // --- Message hashing --- //

    /**
     * @notice Compute the Dogecoin Core-compatible `signmessage` digest of a message.
     * @dev digest = sha256(sha256(compactSize(25) || magic || compactSize(len) || message)).
     *      Reverts with {ErrorMessageTooLong} for messages longer than {MAX_MESSAGE_LENGTH}.
     * @param message The raw message bytes (Dogecoin Core RPC signs UTF-8 strings, but any
     *        byte string a wallet is willing to sign is acceptable here).
     * @return digest The 32-byte double-SHA256 digest to use as `dogeMessageHash`.
     */
    function dogecoinMessageHash(bytes memory message) internal pure returns (bytes32 digest) {
        uint256 len = message.length;
        if (len > MAX_MESSAGE_LENGTH) {
            revert ErrorMessageTooLong(len, MAX_MESSAGE_LENGTH);
        }
        // MESSAGE_MAGIC is 25 bytes => its CompactSize prefix is the single byte 0x19.
        digest = sha256(
            abi.encodePacked(sha256(abi.encodePacked(bytes1(0x19), MESSAGE_MAGIC, _compactSize(len), message)))
        );
    }

    // --- Compact signature header --- //

    /**
     * @notice Parse a Dogecoin compact-signature header byte.
     * @dev Valid headers are 27..34: code = header - 27, recId = code & 3,
     *      compressed = code >= 4. Reverts with {ErrorInvalidSignatureHeader} outside
     *      [27, 34] and {ErrorUnsupportedRecoveryId} for recId 2/3 (EVM ecrecover only
     *      supports recovery ids 0 and 1; ids 2/3 require r >= n, probability ~2^-128).
     * @param header The first byte of the 65-byte compact signature.
     * @return recId The recovery id (0 or 1).
     * @return compressed Whether the recovered public key is serialized compressed.
     */
    function parseHeader(uint8 header) internal pure returns (uint8 recId, bool compressed) {
        if (header < 27 || header > 34) {
            revert ErrorInvalidSignatureHeader(header);
        }
        uint8 code = header - 27;
        recId = code & 3;
        compressed = code >= 4;
        if (recId > 1) {
            revert ErrorUnsupportedRecoveryId(recId);
        }
    }

    // --- Public key utilities --- //

    /**
     * @notice Check whether (x, y) is a valid secp256k1 curve point.
     * @dev Verifies x, y < p, y != 0, and y^2 ≡ x^3 + 7 (mod p). The point at infinity
     *      has no affine encoding and is excluded.
     * @param x The public key x coordinate.
     * @param y The public key y coordinate.
     * @return True if (x, y) lies on secp256k1.
     */
    function isOnCurve(bytes32 x, bytes32 y) internal pure returns (bool) {
        uint256 xv = uint256(x);
        uint256 yv = uint256(y);
        if (xv >= SECP256K1_P || yv >= SECP256K1_P || yv == 0) {
            return false;
        }
        // y^2 == x^3 + 7 (mod p)
        return
            mulmod(yv, yv, SECP256K1_P) == addmod(mulmod(xv, mulmod(xv, xv, SECP256K1_P), SECP256K1_P), 7, SECP256K1_P);
    }

    /**
     * @notice Compute the Dogecoin P2PKH key hash (HASH160) of a public key.
     * @dev keyHash = ripemd160(sha256(serializedPubkey)) where the serialization is
     *      (0x02|0x03) || x for compressed keys or 0x04 || x || y for uncompressed keys.
     *      Pure serialization utility: does NOT validate that (x, y) is on the curve;
     *      callers needing that guarantee should check {isOnCurve} first.
     * @param x The public key x coordinate.
     * @param y The public key y coordinate.
     * @param compressed Whether to serialize the key in compressed form.
     * @return keyHash The 20-byte P2PKH key hash.
     */
    function p2pkhFromPubKey(
        bytes32 x,
        bytes32 y,
        bool compressed
    ) internal pure returns (bytes20 keyHash) {
        if (compressed) {
            keyHash = _hash160(abi.encodePacked(uint256(y) & 1 == 1 ? bytes1(0x03) : bytes1(0x02), x));
        } else {
            keyHash = _hash160(abi.encodePacked(bytes1(0x04), x, y));
        }
    }

    // --- Verification --- //

    /**
     * @notice Recover the Dogecoin P2PKH key hash proven by a compact signature.
     * @dev Validates the header and the public key witness (reverting on malformed input),
     *      then checks that `ecrecover` binds the signature to the witness. Returns
     *      ok = false (with keyHash = 0) if the signature is invalid or does not match
     *      the witness.
     * @param dogeMessageHash The Dogecoin signmessage digest (see {dogecoinMessageHash}).
     * @param header The compact-signature header byte (27..34).
     * @param r The signature r value.
     * @param s The signature s value.
     * @param x The public key witness x coordinate.
     * @param y The public key witness y coordinate.
     * @return keyHash The 20-byte P2PKH key hash of the signer (0 if !ok).
     * @return ok Whether the signature is valid and bound to the witness.
     */
    function recoverP2PKH(
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) internal pure returns (bytes20 keyHash, bool ok) {
        (uint8 recId, bool compressed) = parseHeader(header);
        if (!isOnCurve(x, y)) {
            revert ErrorInvalidPublicKey(x, y);
        }

        address recovered = ecrecover(dogeMessageHash, 27 + recId, r, s);
        if (recovered == address(0)) {
            return (bytes20(0), false);
        }
        if (recovered != address(uint160(uint256(keccak256(abi.encodePacked(x, y)))))) {
            return (bytes20(0), false);
        }

        keyHash = p2pkhFromPubKey(x, y, compressed);
        ok = true;
    }

    /**
     * @notice Verify that the owner of a Dogecoin P2PKH key hash signed a message hash.
     * @dev See {recoverP2PKH} for the revert-vs-false policy. The expected key hash
     *      comparison also covers a wrong compressed flag, since flipping compression
     *      changes the serialized key and therefore the HASH160.
     * @param expectedKeyHash The 20-byte P2PKH key hash the signature must prove.
     * @param dogeMessageHash The Dogecoin signmessage digest (see {dogecoinMessageHash}).
     * @param header The compact-signature header byte (27..34).
     * @param r The signature r value.
     * @param s The signature s value.
     * @param x The public key witness x coordinate.
     * @param y The public key witness y coordinate.
     * @return True if the signature proves ownership of `expectedKeyHash`.
     */
    function verifyP2PKH(
        bytes20 expectedKeyHash,
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) internal pure returns (bool) {
        (bytes20 keyHash, bool ok) = recoverP2PKH(dogeMessageHash, header, r, s, x, y);
        return ok && keyHash == expectedKeyHash;
    }

    // --- Internal helpers --- //

    /**
     * @dev Encode a length as a Bitcoin/Dogecoin CompactSize integer.
     *      len < 0xfd  => single byte;
     *      len <= 0xffff => 0xfd || uint16 little-endian.
     *      Larger encodings (0xfe/0xff) are unreachable because callers enforce
     *      {MAX_MESSAGE_LENGTH}. Note: little-endian, so the bytes are emitted manually
     *      (abi.encodePacked(uint16) would be big-endian).
     */
    function _compactSize(uint256 len) private pure returns (bytes memory) {
        if (len < 0xfd) {
            return abi.encodePacked(bytes1(uint8(len)));
        }
        return abi.encodePacked(bytes1(0xfd), bytes1(uint8(len)), bytes1(uint8(len >> 8)));
    }

    /**
     * @dev HASH160 = ripemd160(sha256(data)). Isolated so the RIPEMD-160 precompile
     *      dependency (address 0x03) can be swapped for a pure-Solidity implementation
     *      if the target chain's prover does not support it.
     */
    function _hash160(bytes memory data) private pure returns (bytes20) {
        return ripemd160(abi.encodePacked(sha256(data)));
    }
}
