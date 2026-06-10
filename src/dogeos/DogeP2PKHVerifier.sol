// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DogeSig} from "./DogeSig.sol";
import {IDogeP2PKHVerifier} from "./IDogeP2PKHVerifier.sol";

/**
 * @title DogeP2PKHVerifier
 * @notice Canonical predeploy exposing Dogecoin Core-compatible `signmessage`
 *         verification to other contracts and tooling.
 * @dev Stateless thin wrapper around the DogeSig library: no owner, no proxy, no
 *      storage. High-volume callers (e.g. batch intent acceptors) should import
 *      DogeSig directly instead of paying an external call per verification; this
 *      predeploy is the stable public interface for occasional/ecosystem use.
 *
 *      Operates on raw 20-byte P2PKH key hashes, not Base58Check address strings
 *      (on-chain address decoding is deliberately out of scope). See DogeSig for the
 *      revert-vs-false error policy and signature-malleability notes.
 */
contract DogeP2PKHVerifier is IDogeP2PKHVerifier {
    // --- Constants --- //

    /// @notice Byte length of the packed payload accepted by {verifyP2PKHPacked}.
    uint256 public constant PACKED_LENGTH = 181;

    // --- Errors --- //

    error ErrorInvalidPackedLength(uint256 length);

    // --- Public functions --- //

    /// @inheritdoc IDogeP2PKHVerifier
    function dogecoinMessageHash(bytes calldata message) external pure returns (bytes32 digest) {
        return DogeSig.dogecoinMessageHash(message);
    }

    /// @inheritdoc IDogeP2PKHVerifier
    function p2pkhFromPubKey(
        bytes32 x,
        bytes32 y,
        bool compressed
    ) external view returns (bytes20 keyHash) {
        return DogeSig.p2pkhFromPubKey(x, y, compressed);
    }

    /// @inheritdoc IDogeP2PKHVerifier
    function recoverP2PKH(
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external view returns (bytes20 keyHash, bool ok) {
        return DogeSig.recoverP2PKH(dogeMessageHash, header, r, s, x, y);
    }

    /// @inheritdoc IDogeP2PKHVerifier
    function verifyP2PKH(
        bytes20 expectedKeyHash,
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external view returns (bool ok) {
        return DogeSig.verifyP2PKH(expectedKeyHash, dogeMessageHash, header, r, s, x, y);
    }

    /// @inheritdoc IDogeP2PKHVerifier
    /// @dev Layout: keyHash(20) || msgHash(32) || header(1) || r(32) || s(32) || x(32) || y(32).
    ///      Reverts with {ErrorInvalidPackedLength} unless `packed` is exactly 181 bytes.
    function verifyP2PKHPacked(bytes calldata packed) external view returns (bool ok) {
        if (packed.length != PACKED_LENGTH) {
            revert ErrorInvalidPackedLength(packed.length);
        }
        return
            DogeSig.verifyP2PKH(
                bytes20(packed[0:20]),
                bytes32(packed[20:52]),
                uint8(packed[52]),
                bytes32(packed[53:85]),
                bytes32(packed[85:117]),
                bytes32(packed[117:149]),
                bytes32(packed[149:181])
            );
    }
}
