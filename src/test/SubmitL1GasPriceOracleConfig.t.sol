// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

import {SubmitL1GasPriceOracleConfig} from "../../scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol";

contract SubmitL1GasPriceOracleConfigHarness is SubmitL1GasPriceOracleConfig {
    function calculateGalileoFee(
        uint256 l1BaseFee,
        uint256 l1BlobBaseFee,
        uint256 commitScalar,
        uint256 blobScalar,
        uint256 penaltyFactor,
        uint256 compressedBytes
    ) external pure returns (uint256) {
        return _calculateGalileoFee(l1BaseFee, l1BlobBaseFee, commitScalar, blobScalar, penaltyFactor, compressedBytes);
    }
}

contract SubmitL1GasPriceOracleConfigTest is Test {
    SubmitL1GasPriceOracleConfigHarness private harness;

    function setUp() external {
        harness = new SubmitL1GasPriceOracleConfigHarness();
    }

    function testCalculateGalileoFee_ProductionCandidate() external view {
        uint256 fee = harness.calculateGalileoFee(
            28_876_074_349_204,
            1_493_712_122_980,
            38_720_000_000,
            8_000_000_000,
            10_000,
            131
        );

        assertEq(fee, 149_973_346_454_534_144);
    }

    function testCalculateGalileoFee_FixedMigrationPair() external view {
        uint256 fee = harness.calculateGalileoFee(1, 1, 38_720_000_000, 8_000_000_000, 10_000, 131);

        assertEq(fee, 6_200);
    }
}
