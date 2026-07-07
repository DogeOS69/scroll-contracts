// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title IDogeP2PKHVerifier
 * @notice Interface for the DogeP2PKHVerifier predeploy: stateless verification of
 *         Dogecoin Core-compatible `signmessage` signatures against P2PKH key hashes.
 * @dev The interface operates on raw 20-byte P2PKH key hashes, not Base58Check address
 *      strings. Callers decode Dogecoin addresses off-chain (or via DogeAddressLib).
 *      See DogeSig for the underlying algorithm, error policy, and malleability notes.
 */
interface IDogeP2PKHVerifier {
    /// @notice Compute the Dogecoin Core-compatible `signmessage` digest of a message.
    /// @param message The raw message bytes (max 1024 bytes).
    /// @return digest The double-SHA256 digest with the Dogecoin message magic.
    function dogecoinMessageHash(bytes calldata message) external pure returns (bytes32 digest);

    /// @notice Compute the Dogecoin P2PKH key hash (HASH160) of a public key.
    /// @dev Pure serialization utility: does NOT validate that (x, y) is a point on the
    ///      secp256k1 curve. Integrators needing that guarantee must check it themselves
    ///      (the verification entrypoints below do validate the witness).
    /// @param x The public key x coordinate.
    /// @param y The public key y coordinate.
    /// @param compressed Whether to serialize the key in compressed form.
    /// @return keyHash The 20-byte P2PKH key hash.
    function p2pkhFromPubKey(
        bytes32 x,
        bytes32 y,
        bool compressed
    ) external view returns (bytes20 keyHash);

    /// @notice Recover the Dogecoin P2PKH key hash proven by a compact signature.
    /// @param dogeMessageHash The Dogecoin signmessage digest.
    /// @param header The compact-signature header byte. Valid range is 27..34, but
    ///        headers 29/30/33/34 carry recovery ids 2/3 and always revert
    ///        (unsupported by EVM ecrecover; ~2^-128 of honest signatures).
    /// @param r The signature r value.
    /// @param s The signature s value.
    /// @param x The public key witness x coordinate.
    /// @param y The public key witness y coordinate.
    /// @return keyHash The 20-byte P2PKH key hash of the signer (0 if !ok).
    /// @return ok Whether the signature is valid and bound to the witness.
    function recoverP2PKH(
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external view returns (bytes20 keyHash, bool ok);

    /// @notice Verify that the owner of a Dogecoin P2PKH key hash signed a message hash.
    /// @param expectedKeyHash The 20-byte P2PKH key hash the signature must prove.
    /// @param dogeMessageHash The Dogecoin signmessage digest.
    /// @param header The compact-signature header byte. Valid range is 27..34, but
    ///        headers 29/30/33/34 carry recovery ids 2/3 and always revert
    ///        (unsupported by EVM ecrecover; ~2^-128 of honest signatures).
    /// @param r The signature r value.
    /// @param s The signature s value.
    /// @param x The public key witness x coordinate.
    /// @param y The public key witness y coordinate.
    /// @return ok True if the signature proves ownership of `expectedKeyHash`.
    function verifyP2PKH(
        bytes20 expectedKeyHash,
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external view returns (bool ok);

    /// @notice Packed-calldata variant of {verifyP2PKH} for hot paths.
    /// @param packed 181 bytes: keyHash(20) || msgHash(32) || header(1) || r(32) ||
    ///        s(32) || x(32) || y(32).
    /// @return ok True if the signature proves ownership of the packed key hash.
    function verifyP2PKHPacked(bytes calldata packed) external view returns (bool ok);
}
