// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";

import {L1GasPriceOracle} from "../L2/predeploys/L1GasPriceOracle.sol";
import {Whitelist} from "../L2/predeploys/Whitelist.sol";

contract L1GasPriceOracleTest is DSTestPlus {
    uint256 private constant PRECISION = 1e9;
    uint256 private constant MAX_OVERHEAD = 30000000 / 16;
    uint256 private constant MAX_SCALAR = 1000 * PRECISION;
    uint256 private constant MAX_COMMIT_SCALAR = 10**9 * PRECISION;
    uint256 private constant MAX_BLOB_SCALAR = 10**9 * PRECISION;

    uint256 private constant PRODUCTION_L1_BASE_FEE = 28_876_074_349_204;
    uint256 private constant PRODUCTION_L1_BLOB_BASE_FEE = 1_493_712_122_980;
    uint256 private constant PRODUCTION_COMMIT_SCALAR = 38_720_000_000;
    uint256 private constant PRODUCTION_BLOB_SCALAR = 8_000_000_000;
    uint256 private constant PRODUCTION_PENALTY_FACTOR = 10_000;

    L1GasPriceOracle private oracle;
    Whitelist private whitelist;

    function setUp() public {
        whitelist = new Whitelist(address(this));
        oracle = new L1GasPriceOracle(address(this));
        oracle.updateWhitelist(address(whitelist));

        address[] memory _accounts = new address[](1);
        _accounts[0] = address(this);
        whitelist.updateWhitelistStatus(_accounts, true);
    }

    function testSetOverhead(uint256 _overhead) external {
        _overhead = bound(_overhead, 0, MAX_OVERHEAD);

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.setOverhead(_overhead);
        hevm.stopPrank();

        // overhead is too large
        hevm.expectRevert(L1GasPriceOracle.ErrExceedMaxOverhead.selector);
        oracle.setOverhead(MAX_OVERHEAD + 1);

        // call by owner, should succeed
        assertEq(oracle.overhead(), 0);
        oracle.setOverhead(_overhead);
        assertEq(oracle.overhead(), _overhead);
    }

    function testSetScalar(uint256 _scalar) external {
        _scalar = bound(_scalar, 0, MAX_SCALAR);

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.setScalar(_scalar);
        hevm.stopPrank();

        // scale is too large
        hevm.expectRevert(L1GasPriceOracle.ErrExceedMaxScalar.selector);
        oracle.setScalar(MAX_SCALAR + 1);

        // call by owner, should succeed
        assertEq(oracle.scalar(), 0);
        oracle.setScalar(_scalar);
        assertEq(oracle.scalar(), _scalar);
    }

    function testSetCommitScalar(uint256 _scalar) external {
        _scalar = bound(_scalar, 0, MAX_COMMIT_SCALAR);

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.setCommitScalar(_scalar);
        hevm.stopPrank();

        // scale is too large
        hevm.expectRevert(L1GasPriceOracle.ErrExceedMaxCommitScalar.selector);
        oracle.setCommitScalar(MAX_COMMIT_SCALAR + 1);

        // call by owner, should succeed
        assertEq(oracle.commitScalar(), 0);
        oracle.setCommitScalar(_scalar);
        assertEq(oracle.commitScalar(), _scalar);
    }

    function testSetBlobScalar(uint256 _scalar) external {
        _scalar = bound(_scalar, 0, MAX_BLOB_SCALAR);

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.setBlobScalar(_scalar);
        hevm.stopPrank();

        // scale is too large
        hevm.expectRevert(L1GasPriceOracle.ErrExceedMaxBlobScalar.selector);
        oracle.setBlobScalar(MAX_COMMIT_SCALAR + 1);

        // call by owner, should succeed
        assertEq(oracle.blobScalar(), 0);
        oracle.setBlobScalar(_scalar);
        assertEq(oracle.blobScalar(), _scalar);
    }

    function testUpdateWhitelist(address _newWhitelist) external {
        hevm.assume(_newWhitelist != address(whitelist));

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.updateWhitelist(_newWhitelist);
        hevm.stopPrank();

        // call by owner, should succeed
        assertEq(address(oracle.whitelist()), address(whitelist));
        oracle.updateWhitelist(_newWhitelist);
        assertEq(address(oracle.whitelist()), _newWhitelist);
    }

    function testEnableCurie() external {
        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.enableCurie();
        hevm.stopPrank();

        // call by owner, should succeed
        assertBoolEq(oracle.isCurie(), false);
        oracle.enableCurie();
        assertBoolEq(oracle.isCurie(), true);

        // enable twice, should revert
        hevm.expectRevert(L1GasPriceOracle.ErrAlreadyInCurieFork.selector);
        oracle.enableCurie();
    }

    function testEnableFeynman() external {
        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.enableFeynman();
        hevm.stopPrank();

        // call by owner, should succeed
        assertBoolEq(oracle.isFeynman(), false);
        oracle.enableFeynman();
        assertBoolEq(oracle.isFeynman(), true);

        // enable twice, should revert
        hevm.expectRevert(L1GasPriceOracle.ErrAlreadyInFeynmanFork.selector);
        oracle.enableFeynman();
    }

    function testSetL1BaseFee(uint256 _baseFee) external {
        _baseFee = bound(_baseFee, 0, 1e9 * 20000); // max 20k gwei

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert(L1GasPriceOracle.ErrCallerNotWhitelisted.selector);
        oracle.setL1BaseFee(_baseFee);
        hevm.stopPrank();

        // call by owner, should succeed
        assertEq(oracle.l1BaseFee(), 0);
        oracle.setL1BaseFee(_baseFee);
        assertEq(oracle.l1BaseFee(), _baseFee);
    }

    function testSetL1BaseFeeAndBlobBaseFee(uint256 _baseFee, uint256 _blobBaseFee) external {
        _baseFee = bound(_baseFee, 0, 1e9 * 20000); // max 20k gwei
        _blobBaseFee = bound(_blobBaseFee, 0, 1e9 * 20000); // max 20k gwei

        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert(L1GasPriceOracle.ErrCallerNotWhitelisted.selector);
        oracle.setL1BaseFeeAndBlobBaseFee(_baseFee, _blobBaseFee);
        hevm.stopPrank();

        // call by owner, should succeed
        assertEq(oracle.l1BaseFee(), 0);
        assertEq(oracle.l1BlobBaseFee(), 0);
        oracle.setL1BaseFeeAndBlobBaseFee(_baseFee, _blobBaseFee);
        assertEq(oracle.l1BaseFee(), _baseFee);
        assertEq(oracle.l1BlobBaseFee(), _blobBaseFee);
    }

    function testGetL1GasUsedBeforeCurie(uint256 _overhead, bytes memory _data) external {
        _overhead = bound(_overhead, 0, MAX_OVERHEAD);

        oracle.setOverhead(_overhead);

        uint256 _gasUsed = _overhead + 4 * 16;
        for (uint256 i = 0; i < _data.length; i++) {
            if (_data[i] == 0) _gasUsed += 4;
            else _gasUsed += 16;
        }

        assertEq(oracle.getL1GasUsed(_data), _gasUsed);
    }

    function testGetL1FeeBeforeCurie(
        uint256 _baseFee,
        uint256 _overhead,
        uint256 _scalar,
        bytes memory _data
    ) external {
        _overhead = bound(_overhead, 0, MAX_OVERHEAD);
        _scalar = bound(_scalar, 0, MAX_SCALAR);
        _baseFee = bound(_baseFee, 0, 1e9 * 20000); // max 20k gwei

        oracle.setOverhead(_overhead);
        oracle.setScalar(_scalar);
        oracle.setL1BaseFee(_baseFee);

        uint256 _gasUsed = _overhead + 4 * 16;
        for (uint256 i = 0; i < _data.length; i++) {
            if (_data[i] == 0) _gasUsed += 4;
            else _gasUsed += 16;
        }

        assertEq(oracle.getL1Fee(_data), (_gasUsed * _baseFee * _scalar) / PRECISION);
    }

    function testGetL1GasUsedCurie(bytes memory _data) external {
        oracle.enableCurie();
        assertEq(oracle.getL1GasUsed(_data), 0);
    }

    function testGetL1FeeCurie(
        uint256 _baseFee,
        uint256 _blobBaseFee,
        uint256 _commitScalar,
        uint256 _blobScalar,
        bytes memory _data
    ) external {
        _baseFee = bound(_baseFee, 0, 1e9 * 20000); // max 20k gwei
        _blobBaseFee = bound(_blobBaseFee, 0, 1e9 * 20000); // max 20k gwei
        _commitScalar = bound(_commitScalar, 0, MAX_COMMIT_SCALAR);
        _blobScalar = bound(_blobScalar, 0, MAX_BLOB_SCALAR);

        oracle.enableCurie();
        oracle.setCommitScalar(_commitScalar);
        oracle.setBlobScalar(_blobScalar);
        oracle.setL1BaseFeeAndBlobBaseFee(_baseFee, _blobBaseFee);

        assertEq(
            oracle.getL1Fee(_data),
            (_commitScalar * _baseFee + _blobScalar * _blobBaseFee * _data.length) / PRECISION
        );
    }

    function testGetL1GasUsedFeynman(bytes memory _data) external {
        oracle.enableFeynman();
        assertEq(oracle.getL1GasUsed(_data), 0);
    }

    function testGetL1FeeFeynman(
        uint256 _baseFee,
        uint256 _blobBaseFee,
        uint256 _commitScalar,
        uint256 _blobScalar,
        uint256 _penaltyFactor,
        bytes memory _data
    ) external {
        _baseFee = bound(_baseFee, 0, 1e9 * 20000); // max 20k gwei
        _blobBaseFee = bound(_blobBaseFee, 0, 1e9 * 20000); // max 20k gwei
        _commitScalar = bound(_commitScalar, 0, MAX_COMMIT_SCALAR);
        _blobScalar = bound(_blobScalar, 0, MAX_BLOB_SCALAR);
        // Note: setPenaltyThreshold is deprecated
        // _penaltyThreshold = bound(_penaltyThreshold, 1e9, 1e9 * 5);
        _penaltyFactor = bound(_penaltyFactor, 1e9, 1e9 * 10); // min 1x, max 10x penalty

        oracle.enableFeynman();
        oracle.setCommitScalar(_commitScalar);
        oracle.setBlobScalar(_blobScalar);
        oracle.setL1BaseFeeAndBlobBaseFee(_baseFee, _blobBaseFee);
        // Note: setPenaltyThreshold is deprecated
        // oracle.setPenaltyThreshold(_penaltyThreshold);
        oracle.setPenaltyFactor(_penaltyFactor);

        assertEq(
            oracle.getL1Fee(_data),
            ((_commitScalar * _baseFee + _blobScalar * _blobBaseFee) * _data.length * _penaltyFactor) /
                PRECISION /
                PRECISION
        );
    }

    function testGetL1FeeGalileo(
        uint256 _baseFee,
        uint256 _blobBaseFee,
        uint256 _commitScalar,
        uint256 _blobScalar,
        uint256 _penaltyFactor,
        bytes memory _data
    ) external {
        _baseFee = bound(_baseFee, 0, 1e9 * 20000); // max 20k gwei
        _blobBaseFee = bound(_blobBaseFee, 0, 1e9 * 20000); // max 20k gwei
        _commitScalar = bound(_commitScalar, 0, MAX_COMMIT_SCALAR);
        _blobScalar = bound(_blobScalar, 0, MAX_BLOB_SCALAR);
        _penaltyFactor = bound(_penaltyFactor, 1, 1e9 * 100);

        oracle.setCommitScalar(_commitScalar);
        oracle.setBlobScalar(_blobScalar);
        oracle.setL1BaseFeeAndBlobBaseFee(_baseFee, _blobBaseFee);
        oracle.setPenaltyFactor(_penaltyFactor);
        // The hard fork activates Galileo after the tuple has been prepared.
        // Store the flag directly so this formula fuzz test can cover the full
        // historical uint256 input range independently of the new guard.
        hevm.store(address(oracle), bytes32(uint256(12)), bytes32(uint256(1)));

        uint256 _baseTerm = (_commitScalar * _baseFee + _blobScalar * _blobBaseFee) * _data.length;
        uint256 _penaltyTerm = (_baseTerm * _data.length) / _penaltyFactor;

        assertEq(oracle.getL1Fee(_data), (_baseTerm + _penaltyTerm) / PRECISION);
    }

    function testEnableGalileo() external {
        // call by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("caller is not the owner");
        oracle.enableGalileo();
        hevm.stopPrank();

        // call by owner, should succeed
        oracle.setPenaltyFactor(PRODUCTION_PENALTY_FACTOR);
        assertBoolEq(oracle.isGalileo(), false);
        oracle.enableGalileo();
        assertBoolEq(oracle.isGalileo(), true);

        // enable twice, should revert
        hevm.expectRevert(L1GasPriceOracle.ErrAlreadyInGalileoFork.selector);
        oracle.enableGalileo();
    }

    function testGetL1FeeGalileoRevertOnUnsetPenaltyFactor() external {
        // Genesis-like state: isGalileo active but penaltyFactor never configured.
        // The Galileo formula divides by penaltyFactor; this must be a clear revert,
        // not Panic(0x12).
        hevm.store(address(oracle), bytes32(uint256(12)), bytes32(uint256(1)));
        assertEq(oracle.penaltyFactor(), 0);

        hevm.expectRevert(L1GasPriceOracle.ErrInvalidPenaltyFactor.selector);
        oracle.getL1Fee(hex"deadbeef");
    }

    function testGalileoFeeGuardConstants() external {
        assertEq(oracle.FEE_GUARD_COMPRESSED_BYTES(), 512);
        assertEq(oracle.MAX_GUARDED_L1_FEE(), 10_000 ether);
    }

    function testGalileoFeeGuardAllowsFeesAboveOneHundredDoge() external {
        oracle.setCommitScalar(PRODUCTION_COMMIT_SCALAR);
        oracle.setBlobScalar(PRODUCTION_BLOB_SCALAR);
        oracle.setPenaltyFactor(PRODUCTION_PENALTY_FACTOR);
        oracle.enableGalileo();

        // Scaling both healthy dynamic fields by 200 produces a guarded fee of
        // about 121.64 DOGE for 512 compressed bytes. The contract guard is a
        // loose technical ceiling and must not act as economic policy.
        uint256 l1BaseFee = PRODUCTION_L1_BASE_FEE * 200;
        uint256 l1BlobBaseFee = PRODUCTION_L1_BLOB_BASE_FEE * 200;
        oracle.setL1BaseFeeAndBlobBaseFee(l1BaseFee, l1BlobBaseFee);

        bytes memory referenceTransaction = new bytes(oracle.FEE_GUARD_COMPRESSED_BYTES());
        uint256 guardedFee = oracle.getL1Fee(referenceTransaction);
        assertGt(guardedFee, 100 ether);
        assertLt(guardedFee, oracle.MAX_GUARDED_L1_FEE());
        assertEq(guardedFee, 121_639_823_168_431_293_097);
    }

    function testDynamicFieldsMayExceedUint64WhenCompleteTupleIsSafe() external {
        oracle.setCommitScalar(1);
        oracle.setBlobScalar(1);
        oracle.setPenaltyFactor(PRODUCTION_PENALTY_FACTOR);
        oracle.enableGalileo();

        uint256 valueAboveUint64 = uint256(type(uint64).max) + 1;
        oracle.setL1BaseFeeAndBlobBaseFee(valueAboveUint64, valueAboveUint64);

        assertEq(oracle.l1BaseFee(), valueAboveUint64);
        assertEq(oracle.l1BlobBaseFee(), valueAboveUint64);

        bytes memory referenceTransaction = new bytes(oracle.FEE_GUARD_COMPRESSED_BYTES());
        assertLt(oracle.getL1Fee(referenceTransaction), oracle.MAX_GUARDED_L1_FEE());
    }

    function testDynamicSetterRevertsWhenCompleteTupleExceedsTechnicalCeiling() external {
        oracle.setCommitScalar(MAX_COMMIT_SCALAR);
        oracle.setPenaltyFactor(1);
        oracle.enableGalileo();

        uint256 l1BaseFee = uint256(type(uint64).max) + 1;
        uint256 guardedFee = _calculateGalileoFee(l1BaseFee, 0, MAX_COMMIT_SCALAR, 0, 1, 512);
        hevm.expectRevert(abi.encodeWithSelector(L1GasPriceOracle.ErrExceedMaxGuardedL1Fee.selector, guardedFee));
        oracle.setL1BaseFeeAndBlobBaseFee(l1BaseFee, 0);
        assertEq(oracle.l1BaseFee(), 0);
        assertEq(oracle.l1BlobBaseFee(), 0);
    }

    function testSingleDynamicSetterRevertsWhenCompleteTupleExceedsTechnicalCeiling() external {
        oracle.setCommitScalar(MAX_COMMIT_SCALAR);
        oracle.setPenaltyFactor(1);
        oracle.enableGalileo();

        uint256 l1BaseFee = uint256(type(uint64).max) + 1;
        uint256 guardedFee = _calculateGalileoFee(l1BaseFee, 0, MAX_COMMIT_SCALAR, 0, 1, 512);
        hevm.expectRevert(abi.encodeWithSelector(L1GasPriceOracle.ErrExceedMaxGuardedL1Fee.selector, guardedFee));
        oracle.setL1BaseFee(l1BaseFee);
        assertEq(oracle.l1BaseFee(), 0);
    }

    function testStaticSetterRevertsWhenCompleteTupleExceedsTechnicalCeiling() external {
        oracle.setPenaltyFactor(1);
        oracle.enableGalileo();

        // With both scalars at zero an individually large dynamic value is
        // harmless and may be stored. Raising commitScalar must validate the
        // resulting full tuple before changing storage.
        uint256 l1BaseFee = uint256(type(uint64).max) + 1;
        oracle.setL1BaseFee(l1BaseFee);
        uint256 guardedFee = _calculateGalileoFee(l1BaseFee, 0, MAX_COMMIT_SCALAR, 0, 1, 512);
        hevm.expectRevert(abi.encodeWithSelector(L1GasPriceOracle.ErrExceedMaxGuardedL1Fee.selector, guardedFee));
        oracle.setCommitScalar(MAX_COMMIT_SCALAR);
        assertEq(oracle.commitScalar(), 0);
    }

    function testBlobScalarSetterRevertsWhenCompleteTupleExceedsTechnicalCeiling() external {
        oracle.setPenaltyFactor(1);
        oracle.enableGalileo();

        uint256 l1BlobBaseFee = uint256(type(uint64).max) + 1;
        oracle.setL1BaseFeeAndBlobBaseFee(0, l1BlobBaseFee);
        uint256 guardedFee = _calculateGalileoFee(0, l1BlobBaseFee, 0, MAX_BLOB_SCALAR, 1, 512);
        hevm.expectRevert(abi.encodeWithSelector(L1GasPriceOracle.ErrExceedMaxGuardedL1Fee.selector, guardedFee));
        oracle.setBlobScalar(MAX_BLOB_SCALAR);
        assertEq(oracle.blobScalar(), 0);
    }

    function testPenaltySetterRevertsWhenCompleteTupleExceedsTechnicalCeiling() external {
        oracle.setCommitScalar(PRODUCTION_COMMIT_SCALAR);
        oracle.setBlobScalar(PRODUCTION_BLOB_SCALAR);
        oracle.setL1BaseFeeAndBlobBaseFee(PRODUCTION_L1_BASE_FEE * 100, PRODUCTION_L1_BLOB_BASE_FEE * 100);
        oracle.setPenaltyFactor(PRODUCTION_PENALTY_FACTOR);
        oracle.enableGalileo();

        uint256 guardedFee = _calculateGalileoFee(
            PRODUCTION_L1_BASE_FEE * 100,
            PRODUCTION_L1_BLOB_BASE_FEE * 100,
            PRODUCTION_COMMIT_SCALAR,
            PRODUCTION_BLOB_SCALAR,
            1,
            512
        );
        hevm.expectRevert(abi.encodeWithSelector(L1GasPriceOracle.ErrExceedMaxGuardedL1Fee.selector, guardedFee));
        oracle.setPenaltyFactor(1);
        assertEq(oracle.penaltyFactor(), PRODUCTION_PENALTY_FACTOR);
    }

    function testEnableGalileoRevertsWhenCompleteTupleExceedsTechnicalCeiling() external {
        oracle.setCommitScalar(MAX_COMMIT_SCALAR);
        uint256 l1BaseFee = uint256(type(uint64).max) + 1;
        oracle.setL1BaseFee(l1BaseFee);
        oracle.setPenaltyFactor(1);

        uint256 guardedFee = _calculateGalileoFee(l1BaseFee, 0, MAX_COMMIT_SCALAR, 0, 1, 512);
        hevm.expectRevert(abi.encodeWithSelector(L1GasPriceOracle.ErrExceedMaxGuardedL1Fee.selector, guardedFee));
        oracle.enableGalileo();
        assertFalse(oracle.isGalileo());
    }

    function testFixedOneOneMigrationTuplePassesTechnicalGuard() external {
        oracle.setPenaltyFactor(PRODUCTION_PENALTY_FACTOR);
        oracle.enableGalileo();

        oracle.setL1BaseFeeAndBlobBaseFee(1, 1);
        oracle.setCommitScalar(PRODUCTION_COMMIT_SCALAR);
        oracle.setBlobScalar(PRODUCTION_BLOB_SCALAR);

        assertEq(oracle.l1BaseFee(), 1);
        assertEq(oracle.l1BlobBaseFee(), 1);
        assertEq(oracle.commitScalar(), PRODUCTION_COMMIT_SCALAR);
        assertEq(oracle.blobScalar(), PRODUCTION_BLOB_SCALAR);
    }

    function _calculateGalileoFee(
        uint256 _l1BaseFee,
        uint256 _l1BlobBaseFee,
        uint256 _commitScalar,
        uint256 _blobScalar,
        uint256 _penaltyFactor,
        uint256 _compressedBytes
    ) private pure returns (uint256) {
        uint256 baseTerm = (_commitScalar * _l1BaseFee + _blobScalar * _l1BlobBaseFee) * _compressedBytes;
        uint256 penaltyTerm = (baseTerm * _compressedBytes) / _penaltyFactor;
        return (baseTerm + penaltyTerm) / PRECISION;
    }

    function testSetStorageDuringUpgrade() external {
        assertFalse(oracle.isFeynman());
        assertFalse(oracle.isGalileo());

        // Feynman upgrade
        hevm.store(address(oracle), bytes32(uint256(11)), bytes32(uint256(1)));
        assertTrue(oracle.isFeynman());
        assertFalse(oracle.isGalileo());

        // GalileoV2 upgrade
        hevm.store(address(oracle), bytes32(uint256(12)), bytes32(uint256(1)));
        assertTrue(oracle.isFeynman());
        assertTrue(oracle.isGalileo());
    }
}
