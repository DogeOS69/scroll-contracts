// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

import {DogeSig} from "../../dogeos/DogeSig.sol";
import {DogeSigTestVectors} from "./DogeSigTestVectors.sol";

/// @dev Wrapper exposing the internal library functions externally so tests can use
///      vm.expectRevert (mirrors DogeAddressLibWrapper in Moat.t.sol).
contract DogeSigWrapper {
    function dogecoinMessageHash(bytes memory message) external pure returns (bytes32) {
        return DogeSig.dogecoinMessageHash(message);
    }

    function parseHeader(uint8 header) external pure returns (uint8 recId, bool compressed) {
        return DogeSig.parseHeader(header);
    }

    function isOnCurve(bytes32 x, bytes32 y) external pure returns (bool) {
        return DogeSig.isOnCurve(x, y);
    }

    function p2pkhFromPubKey(
        bytes32 x,
        bytes32 y,
        bool compressed
    ) external pure returns (bytes20) {
        return DogeSig.p2pkhFromPubKey(x, y, compressed);
    }

    function recoverP2PKH(
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external pure returns (bytes20 keyHash, bool ok) {
        return DogeSig.recoverP2PKH(dogeMessageHash, header, r, s, x, y);
    }

    function verifyP2PKH(
        bytes20 expectedKeyHash,
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external pure returns (bool) {
        return DogeSig.verifyP2PKH(expectedKeyHash, dogeMessageHash, header, r, s, x, y);
    }
}

contract DogeSigTest is Test, DogeSigTestVectors {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SECP256K1_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    DogeSigWrapper internal _lib;

    function setUp() public {
        _lib = new DogeSigWrapper();
    }

    // --- Positive vectors --- //

    function testDogecoinMessageHash_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            assertEq(_lib.dogecoinMessageHash(vectors[i].message), vectors[i].msgHash, vectors[i].name);
        }
    }

    function testP2pkhFromPubKey_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            assertEq(
                _lib.p2pkhFromPubKey(vectors[i].x, vectors[i].y, vectors[i].compressed),
                vectors[i].keyHash,
                vectors[i].name
            );
        }
    }

    function testParseHeader_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            (uint8 recId, bool compressed) = _lib.parseHeader(vectors[i].header);
            assertLe(recId, 1, vectors[i].name);
            assertEq(compressed, vectors[i].compressed, vectors[i].name);
        }
    }

    function testIsOnCurve_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            assertTrue(_lib.isOnCurve(vectors[i].x, vectors[i].y), vectors[i].name);
        }
    }

    function testRecoverP2PKH_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            (bytes20 keyHash, bool ok) = _lib.recoverP2PKH(v.msgHash, v.header, v.r, v.s, v.x, v.y);
            assertTrue(ok, v.name);
            assertEq(keyHash, v.keyHash, v.name);
        }
    }

    function testVerifyP2PKH_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            assertTrue(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, v.x, v.y), v.name);
        }
    }

    /// @dev Dogecoin Core parity: no low-s rule, so the malleated twin
    ///      (n - s, recId ^ 1) of any valid signature also verifies.
    function testVerifyP2PKH_HighSTwinVerifies() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            bytes32 sTwin = bytes32(SECP256K1_N - uint256(v.s));
            uint8 code = v.header - 27;
            uint8 headerTwin = 27 + ((code & 3) ^ 1) + (code >= 4 ? 4 : 0);
            assertTrue(_lib.verifyP2PKH(v.keyHash, v.msgHash, headerTwin, v.r, sTwin, v.x, v.y), v.name);
        }
    }

    // --- Verification failures (return false) --- //

    function testVerifyP2PKH_WrongMessageHash() external view {
        SigVector memory v = _sigVectors()[0];
        bytes32 wrongHash = _lib.dogecoinMessageHash("Very wrong. Such tamper.");
        assertFalse(_lib.verifyP2PKH(v.keyHash, wrongHash, v.header, v.r, v.s, v.x, v.y));
    }

    function testVerifyP2PKH_WrongKeyHash() external view {
        SigVector memory v = _sigVectors()[0];
        bytes20 wrongKeyHash = bytes20(uint160(v.keyHash) ^ 1);
        assertFalse(_lib.verifyP2PKH(wrongKeyHash, v.msgHash, v.header, v.r, v.s, v.x, v.y));
    }

    function testVerifyP2PKH_WrongWitness() external view {
        SigVector[] memory vectors = _sigVectors();
        // Vector 1 uses a different private key, so its (valid, on-curve) public key
        // does not match vector 0's signature.
        SigVector memory v = vectors[0];
        SigVector memory other = vectors[1];
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, other.x, other.y));
        (bytes20 keyHash, bool ok) = _lib.recoverP2PKH(v.msgHash, v.header, v.r, v.s, other.x, other.y);
        assertFalse(ok);
        assertEq(keyHash, bytes20(0));
    }

    function testVerifyP2PKH_FlippedCompressedFlag() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            uint8 flippedHeader = v.compressed ? v.header - 4 : v.header + 4;
            assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, flippedHeader, v.r, v.s, v.x, v.y), v.name);
        }
    }

    function testVerifyP2PKH_MutatedR() external view {
        SigVector memory v = _sigVectors()[0];
        bytes32 badR = bytes32(uint256(v.r) ^ 1);
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, badR, v.s, v.x, v.y));
    }

    function testVerifyP2PKH_MutatedS() external view {
        SigVector memory v = _sigVectors()[0];
        bytes32 badS = bytes32(uint256(v.s) ^ 1);
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, badS, v.x, v.y));
    }

    function testVerifyP2PKH_ZeroAndOutOfRangeSignatureValues() external view {
        SigVector memory v = _sigVectors()[0];
        // ecrecover returns address(0) for all of these => verify returns false.
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, bytes32(0), v.s, v.x, v.y));
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, bytes32(0), v.x, v.y));
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, bytes32(SECP256K1_N), v.x, v.y));
    }

    // --- Malformed input (revert) --- //

    function testParseHeader_RevertInvalidHeader() external {
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidSignatureHeader.selector, 26));
        _lib.parseHeader(26);

        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidSignatureHeader.selector, 35));
        _lib.parseHeader(35);

        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidSignatureHeader.selector, 0));
        _lib.parseHeader(0);
    }

    function testParseHeader_RevertUnsupportedRecoveryId() external {
        uint8[4] memory headers = [29, 30, 33, 34];
        for (uint256 i = 0; i < headers.length; i++) {
            uint8 recId = (headers[i] - 27) & 3;
            vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorUnsupportedRecoveryId.selector, recId));
            _lib.parseHeader(headers[i]);
        }
    }

    function testVerifyP2PKH_RevertInvalidHeader() external {
        SigVector memory v = _sigVectors()[0];
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidSignatureHeader.selector, 26));
        _lib.verifyP2PKH(v.keyHash, v.msgHash, 26, v.r, v.s, v.x, v.y);
    }

    function testVerifyP2PKH_RevertInvalidPublicKey() external {
        SigVector memory v = _sigVectors()[0];

        // Off-curve: y + 1.
        bytes32 badY = bytes32(uint256(v.y) + 1);
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidPublicKey.selector, v.x, badY));
        _lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, v.x, badY);

        // Coordinates >= p.
        bytes32 pAsX = bytes32(SECP256K1_P);
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidPublicKey.selector, pAsX, v.y));
        _lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, pAsX, v.y);

        bytes32 pAsY = bytes32(SECP256K1_P);
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidPublicKey.selector, v.x, pAsY));
        _lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, v.x, pAsY);

        // Point at infinity encoding (0, 0).
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidPublicKey.selector, bytes32(0), bytes32(0)));
        _lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, bytes32(0), bytes32(0));
    }

    function testDogecoinMessageHash_RevertTooLong() external {
        bytes memory longMessage = new bytes(1025);
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorMessageTooLong.selector, 1025, 1024));
        _lib.dogecoinMessageHash(longMessage);
    }

    function testIsOnCurve_RejectsInvalidPoints() external view {
        SigVector memory v = _sigVectors()[0];
        assertFalse(_lib.isOnCurve(v.x, bytes32(uint256(v.y) + 1)));
        assertFalse(_lib.isOnCurve(bytes32(SECP256K1_P), v.y));
        assertFalse(_lib.isOnCurve(v.x, bytes32(SECP256K1_P)));
        assertFalse(_lib.isOnCurve(bytes32(0), bytes32(0)));
        assertFalse(_lib.isOnCurve(v.x, bytes32(0)));
    }

    // --- Fuzz --- //

    function testFuzz_dogecoinMessageHash_NeverReverts(bytes calldata message) external view {
        vm.assume(message.length <= 1024);
        _lib.dogecoinMessageHash(message);
    }

    function testFuzz_verifyP2PKH_MutatedSignatureNeverVerifies(uint8 wordChoice, uint256 xorMask) external view {
        vm.assume(xorMask != 0);
        SigVector memory v = _sigVectors()[0];
        bytes32 r = v.r;
        bytes32 s = v.s;
        if (wordChoice % 2 == 0) {
            r = bytes32(uint256(r) ^ xorMask);
        } else {
            s = bytes32(uint256(s) ^ xorMask);
        }
        // The only other accepting (r, s) for this recId-parity pair is the high-s twin,
        // which pairs with the opposite recovery id; with the original header any
        // mutation must fail.
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, r, s, v.x, v.y));
    }

    function testFuzz_parseHeader_Partition(uint8 header) external {
        if (header < 27 || header > 34) {
            vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidSignatureHeader.selector, header));
            _lib.parseHeader(header);
        } else if (((header - 27) & 3) > 1) {
            vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorUnsupportedRecoveryId.selector, (header - 27) & 3));
            _lib.parseHeader(header);
        } else {
            (uint8 recId, bool compressed) = _lib.parseHeader(header);
            assertEq(recId, (header - 27) & 3);
            assertEq(compressed, header >= 31);
        }
    }
}
