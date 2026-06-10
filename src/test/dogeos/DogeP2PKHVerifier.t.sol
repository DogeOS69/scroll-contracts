// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DogeSig} from "../../dogeos/DogeSig.sol";
import {DogeP2PKHVerifier} from "../../dogeos/DogeP2PKHVerifier.sol";
import {IDogeP2PKHVerifier} from "../../dogeos/IDogeP2PKHVerifier.sol";
import {DogeSigTestVectors} from "./DogeSigTestVectors.sol";

contract DogeP2PKHVerifierTest is Test, DogeSigTestVectors {
    IDogeP2PKHVerifier internal _verifier;

    function setUp() public {
        _verifier = new DogeP2PKHVerifier();
    }

    function _pack(
        bytes20 keyHash,
        bytes32 msgHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(keyHash, msgHash, header, r, s, x, y);
    }

    function _packVector(SigVector memory v) internal pure returns (bytes memory) {
        return _pack(v.keyHash, v.msgHash, v.header, v.r, v.s, v.x, v.y);
    }

    // --- ABI entrypoints --- //

    function testDogecoinMessageHash_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            assertEq(_verifier.dogecoinMessageHash(vectors[i].message), vectors[i].msgHash, vectors[i].name);
        }
    }

    function testP2pkhFromPubKey_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            assertEq(
                _verifier.p2pkhFromPubKey(vectors[i].x, vectors[i].y, vectors[i].compressed),
                vectors[i].keyHash,
                vectors[i].name
            );
        }
    }

    function testRecoverP2PKH_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            (bytes20 keyHash, bool ok) = _verifier.recoverP2PKH(v.msgHash, v.header, v.r, v.s, v.x, v.y);
            assertTrue(ok, v.name);
            assertEq(keyHash, v.keyHash, v.name);
        }
    }

    function testVerifyP2PKH_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            assertTrue(_verifier.verifyP2PKH(v.keyHash, v.msgHash, v.header, v.r, v.s, v.x, v.y), v.name);
        }
    }

    function testVerifyP2PKH_Negatives() external view {
        // Exhaustive negative coverage lives in DogeSig.t.sol; spot-check the wrapper.
        SigVector memory v = _sigVectors()[0];
        assertFalse(_verifier.verifyP2PKH(bytes20(uint160(v.keyHash) ^ 1), v.msgHash, v.header, v.r, v.s, v.x, v.y));
        assertFalse(_verifier.verifyP2PKH(v.keyHash, v.msgHash, v.header, bytes32(uint256(v.r) ^ 1), v.s, v.x, v.y));
    }

    function testVerifyP2PKH_RevertsPropagate() external {
        SigVector memory v = _sigVectors()[0];
        vm.expectRevert(abi.encodeWithSelector(DogeSig.ErrorInvalidSignatureHeader.selector, 26));
        _verifier.verifyP2PKH(v.keyHash, v.msgHash, 26, v.r, v.s, v.x, v.y);
    }

    // --- Packed entrypoint --- //

    function testVerifyP2PKHPacked_Vectors() external view {
        SigVector[] memory vectors = _sigVectors();
        for (uint256 i = 0; i < vectors.length; i++) {
            SigVector memory v = vectors[i];
            bytes memory packed = _packVector(v);
            assertEq(packed.length, 181, "packed layout must be 181 bytes");
            assertTrue(_verifier.verifyP2PKHPacked(packed), v.name);
        }
    }

    function testVerifyP2PKHPacked_TamperedFields() external view {
        SigVector memory v = _sigVectors()[0];

        assertFalse(
            _verifier.verifyP2PKHPacked(_pack(bytes20(uint160(v.keyHash) ^ 1), v.msgHash, v.header, v.r, v.s, v.x, v.y))
        );
        assertFalse(
            _verifier.verifyP2PKHPacked(_pack(v.keyHash, bytes32(uint256(v.msgHash) ^ 1), v.header, v.r, v.s, v.x, v.y))
        );
        assertFalse(
            _verifier.verifyP2PKHPacked(_pack(v.keyHash, v.msgHash, v.header, bytes32(uint256(v.r) ^ 1), v.s, v.x, v.y))
        );
        assertFalse(
            _verifier.verifyP2PKHPacked(_pack(v.keyHash, v.msgHash, v.header, v.r, bytes32(uint256(v.s) ^ 1), v.x, v.y))
        );
    }

    function testVerifyP2PKHPacked_RevertInvalidLength() external {
        vm.expectRevert(abi.encodeWithSelector(DogeP2PKHVerifier.ErrorInvalidPackedLength.selector, 0));
        _verifier.verifyP2PKHPacked("");

        bytes memory tooShort = new bytes(180);
        vm.expectRevert(abi.encodeWithSelector(DogeP2PKHVerifier.ErrorInvalidPackedLength.selector, 180));
        _verifier.verifyP2PKHPacked(tooShort);

        bytes memory tooLong = new bytes(182);
        vm.expectRevert(abi.encodeWithSelector(DogeP2PKHVerifier.ErrorInvalidPackedLength.selector, 182));
        _verifier.verifyP2PKHPacked(tooLong);
    }

    /// @dev The packed entrypoint must behave exactly like the field-level ABI entrypoint,
    ///      both for results and for reverts.
    function testFuzz_PackedEquivalence(
        bytes20 keyHash,
        bytes32 msgHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external view {
        bytes memory packed = _pack(keyHash, msgHash, header, r, s, x, y);

        (bool unpackedSuccess, bytes memory unpackedRet) = address(_verifier).staticcall(
            abi.encodeCall(IDogeP2PKHVerifier.verifyP2PKH, (keyHash, msgHash, header, r, s, x, y))
        );
        (bool packedSuccess, bytes memory packedRet) = address(_verifier).staticcall(
            abi.encodeCall(IDogeP2PKHVerifier.verifyP2PKHPacked, (packed))
        );

        assertEq(packedSuccess, unpackedSuccess, "revert behavior must match");
        if (unpackedSuccess) {
            assertEq(abi.decode(packedRet, (bool)), abi.decode(unpackedRet, (bool)), "result must match");
        } else {
            assertEq(packedRet, unpackedRet, "revert data must match");
        }
    }

    // --- Sanity: works with a vm.sign-produced signature --- //

    function testVerifyP2PKH_VmSignedSignature() external {
        uint256 pk = 0xA11CE;
        Vm.Wallet memory wallet = vm.createWallet(pk);

        bytes32 msgHash = _verifier.dogecoinMessageHash("vm.sign round trip");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, msgHash);

        // v is 27/28; +4 marks the key as compressed.
        uint8 header = v + 4;
        bytes20 keyHash = _verifier.p2pkhFromPubKey(bytes32(wallet.publicKeyX), bytes32(wallet.publicKeyY), true);

        assertTrue(
            _verifier.verifyP2PKH(
                keyHash,
                msgHash,
                header,
                r,
                s,
                bytes32(wallet.publicKeyX),
                bytes32(wallet.publicKeyY)
            )
        );
    }
}
