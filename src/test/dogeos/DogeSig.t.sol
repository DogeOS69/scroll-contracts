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
    ) external view returns (bytes20) {
        return DogeSig.p2pkhFromPubKey(x, y, compressed);
    }

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

    function verifyP2PKH(
        bytes20 expectedKeyHash,
        bytes32 dogeMessageHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external view returns (bool) {
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
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, bytes32(SECP256K1_N), v.s, v.x, v.y));
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, bytes32(type(uint256).max), v.s, v.x, v.y));
        assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, bytes32(type(uint256).max), v.x, v.y));
    }

    /// @dev (x, p - y) is the curve point's negation: it passes isOnCurve, so only the
    ///      keccak256(x || y) witness binding rejects it. This pins the binding down -
    ///      a future "x-only" refactor that dropped y from the binding would silently
    ///      accept the negated witness and become exploitable.
    function testVerifyP2PKH_NegatedWitnessRejected() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            bytes32 negY = bytes32(SECP256K1_P - uint256(v.y));
            assertTrue(_lib.isOnCurve(v.x, negY), v.name);
            assertFalse(_lib.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, v.x, negY), v.name);
            (bytes20 keyHash, bool ok) = _lib.recoverP2PKH(v.msgHash, v.header, v.r, v.s, v.x, negY);
            assertFalse(ok, v.name);
            assertEq(keyHash, bytes20(0), v.name);
        }
    }

    /// @dev The committed vector set must cover the full supported header matrix:
    ///      27 (uncompressed/recId 0), 28 (uncompressed/recId 1), 31 (compressed/recId 0),
    ///      32 (compressed/recId 1).
    function testVectors_CoverFullHeaderMatrix() external pure {
        SigVector[] memory vectors = _sigVectors();
        bool[35] memory seen;
        for (uint256 i = 0; i < vectors.length; i++) {
            seen[vectors[i].header] = true;
        }
        assertTrue(seen[27] && seen[28] && seen[31] && seen[32], "header matrix incomplete");
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

    // --- Dogecoin Core fixture --- //

    /// @dev Anchors the library to the real protocol: this fixture was captured from an
    ///      actual Dogecoin Core node, NOT generated by scripts/dogeos/gen_doge_sig_vectors.py,
    ///      so a shared spec misreading between the Python generator and this library
    ///      (wrong magic, single vs double SHA-256, CompactSize bugs, ...) cannot pass here.
    ///
    ///      Captured from Dogecoin Core 1.14.9 (/Shibetoshi:1.14.9/) in -regtest mode:
    ///        dogecoin-cli -regtest getnewaddress
    ///          -> mff7Fv8uwEoWCBvnbwo5pX7ukeCoPDEH3h          (prefix 0x6f, regtest P2PKH)
    ///        dogecoin-cli -regtest signmessage <addr> "DogeOS signmessage fixture"
    ///          -> HxZN7PyeijqYQ0fttbYRLQTt2g8r50Q8weJyZwDR6+IgVTjAMDcpwG6idGx3xyyAmFWihY8lJOnS11bVcV2cLm0=
    ///        dogecoin-cli -regtest validateaddress <addr> | .pubkey
    ///          -> 03142364aacf2c7e710e94f1b4b34c40e9dbfa45b93f247464a9cab569e79b77b9
    ///        dogecoin-cli -regtest verifymessage <addr> <sig> "DogeOS signmessage fixture"
    ///          -> true
    ///      keyHash = Base58Check payload of the address; header/r/s = Base64-decoded
    ///      65-byte compact signature; (x, y) = decompressed pubkey (witness only - the
    ///      keccak binding ties it to Core's signature).
    function testVerifyP2PKH_DogecoinCoreFixture() external view {
        bytes memory message = "DogeOS signmessage fixture";
        bytes20 keyHash = hex"018acf4c5710029e360ba3d29cef5c6dddbb659d";
        uint8 header = 31; // compressed, recId 0
        bytes32 r = 0x164decfc9e8a3a984347edb5b6112d04edda0f2be7443cc1e2726700d1ebe220;
        bytes32 s = 0x5538c0303729c06ea2746c77c72c809855a2858f2524e9d2d756d5715d9c2e6d;
        bytes32 x = 0x142364aacf2c7e710e94f1b4b34c40e9dbfa45b93f247464a9cab569e79b77b9;
        bytes32 y = 0xe8d677d2eb14750d7a96001b8bb8ad7601e16209372100578e81711b58749b55;

        bytes32 msgHash = _lib.dogecoinMessageHash(message);
        assertEq(msgHash, 0x8eafacef30410bc4c5713e7e28874b9a02dea012a1d32032bc8253b5dc648db4);
        assertEq(_lib.p2pkhFromPubKey(x, y, true), keyHash);
        assertTrue(_lib.verifyP2PKH(keyHash, msgHash, header, r, s, x, y));

        // wrong message must fail against the Core signature too
        bytes32 wrongHash = _lib.dogecoinMessageHash("DogeOS signmessage fixture!");
        assertFalse(_lib.verifyP2PKH(keyHash, wrongHash, header, r, s, x, y));
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
        // Accepting (r, s) pairs other than the known signature exist mathematically
        // (for essentially every r there is one s that recovers this key), but finding
        // any of them is computationally infeasible - it would constitute a forgery.
        // The high-s twin pairs with the opposite recovery id, so with the original
        // header every reachable mutation must fail.
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
