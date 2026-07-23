// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L1GasPriceOracle} from "../../src/L2/predeploys/L1GasPriceOracle.sol";

import {CONFIG_PATH, CONFIG_CONTRACTS_PATH} from "./Constants.sol";

/// @notice Performs a guarded, transaction-by-transaction Galileo fee migration.
/// @dev The migration dynamic pair is deliberately fixed at 1/1. A
///      fresh production candidate from the signer-free fee-oracle dry-run path
///      is still required so the final production tuple can be capped before
///      the new writer is allowed on chain.
contract SubmitL1GasPriceOracleConfig is Script {
    using stdToml for string;

    uint256 private constant MIGRATION_L1_BASE_FEE = 1;
    uint256 private constant MIGRATION_L1_BLOB_BASE_FEE = 1;

    struct Inputs {
        address oracle;
        address whitelist;
        uint256 expectedChainId;
        uint256 productionL1BaseFee;
        uint256 productionL1BlobBaseFee;
        uint256 productionObservedAt;
        uint256 maxProductionAge;
        uint256 maxProductionL1BaseFee;
        uint256 maxProductionL1BlobBaseFee;
        uint256 feeGuardCompressedBytes;
        uint256 maxL1DataFee;
        uint256 commitScalar;
        uint256 blobScalar;
        uint256 penaltyFactor;
    }

    /// @dev The old all-at-once entrypoint is intentionally disabled. The shell
    ///      orchestrator calls one mutating entrypoint at a time and performs a
    ///      separate RPC readback before it permits the next transaction.
    function run() external pure {
        revert("unsafe run() disabled; use guarded step entrypoints");
    }

    function dryRun() external view {
        Inputs memory inputs = _readInputs();
        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflightCommon(inputs, oracle);

        console.log("");
        console.log("guarded L1GasPriceOracle fee migration dry run");
        _printState(inputs, oracle);
    }

    function setMigrationDynamic() external {
        (, L1GasPriceOracle oracle, uint256 ownerPrivateKey) = _prepareOwnerStep();

        console.log("step 1/4: set fixed 1/1 migration dynamic fee pair");
        vm.startBroadcast(ownerPrivateKey);
        if (oracle.l1BaseFee() == MIGRATION_L1_BASE_FEE && oracle.l1BlobBaseFee() == MIGRATION_L1_BLOB_BASE_FEE) {
            console.log("already set - skipping");
        } else {
            oracle.setL1BaseFeeAndBlobBaseFee(MIGRATION_L1_BASE_FEE, MIGRATION_L1_BLOB_BASE_FEE);
        }
        vm.stopBroadcast();
    }

    function setCommitScalar() external {
        (Inputs memory inputs, L1GasPriceOracle oracle, uint256 ownerPrivateKey) = _prepareOwnerStep();
        _requireMigrationDynamic(oracle);

        console.log("step 2/4: set commit scalar");
        vm.startBroadcast(ownerPrivateKey);
        if (oracle.commitScalar() == inputs.commitScalar) {
            console.log("already set - skipping");
        } else {
            oracle.setCommitScalar(inputs.commitScalar);
        }
        vm.stopBroadcast();
    }

    function setBlobScalar() external {
        (Inputs memory inputs, L1GasPriceOracle oracle, uint256 ownerPrivateKey) = _prepareOwnerStep();
        _requireMigrationDynamic(oracle);
        require(oracle.commitScalar() == inputs.commitScalar, "commit scalar step is incomplete");

        console.log("step 3/4: set blob scalar");
        vm.startBroadcast(ownerPrivateKey);
        if (oracle.blobScalar() == inputs.blobScalar) {
            console.log("already set - skipping");
        } else {
            oracle.setBlobScalar(inputs.blobScalar);
        }
        vm.stopBroadcast();
    }

    function setPenaltyFactor() external {
        (Inputs memory inputs, L1GasPriceOracle oracle, uint256 ownerPrivateKey) = _prepareOwnerStep();
        _requireMigrationDynamic(oracle);
        require(oracle.commitScalar() == inputs.commitScalar, "commit scalar step is incomplete");
        require(oracle.blobScalar() == inputs.blobScalar, "blob scalar step is incomplete");

        console.log("step 4/4: set penalty factor");
        vm.startBroadcast(ownerPrivateKey);
        if (oracle.penaltyFactor() == inputs.penaltyFactor) {
            console.log("already set - skipping");
        } else {
            oracle.setPenaltyFactor(inputs.penaltyFactor);
        }
        vm.stopBroadcast();
    }

    function verifyMigrationDynamic() external view {
        Inputs memory inputs = _readInputs();
        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflightCommon(inputs, oracle);
        _requireMigrationDynamic(oracle);
    }

    function verifyCommitScalar() external view {
        Inputs memory inputs = _readInputs();
        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflightCommon(inputs, oracle);
        _requireMigrationDynamic(oracle);
        require(oracle.commitScalar() == inputs.commitScalar, "commit scalar verification failed");
    }

    function verifyBlobScalar() external view {
        Inputs memory inputs = _readInputs();
        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflightCommon(inputs, oracle);
        _requireMigrationDynamic(oracle);
        require(oracle.commitScalar() == inputs.commitScalar, "commit scalar verification failed");
        require(oracle.blobScalar() == inputs.blobScalar, "blob scalar verification failed");
    }

    function verifyFinalState() external view {
        Inputs memory inputs = _readInputs();
        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflightCommon(inputs, oracle);
        _requireMigrationDynamic(oracle);
        require(oracle.commitScalar() == inputs.commitScalar, "commit scalar verification failed");
        require(oracle.blobScalar() == inputs.blobScalar, "blob scalar verification failed");
        require(oracle.penaltyFactor() == inputs.penaltyFactor, "penalty factor verification failed");
    }

    function _prepareOwnerStep()
        private
        view
        returns (
            Inputs memory inputs,
            L1GasPriceOracle oracle,
            uint256 ownerPrivateKey
        )
    {
        inputs = _readInputs();
        oracle = L1GasPriceOracle(inputs.oracle);
        ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");

        _preflightCommon(inputs, oracle);

        address signer = vm.addr(ownerPrivateKey);
        require(signer == oracle.owner(), "OWNER_PRIVATE_KEY does not control oracle owner");
        require(oracle.whitelist().isSenderAllowed(signer), "oracle owner is not whitelisted");

        console.log("signer:       ", signer);
        console.log("oracle:       ", inputs.oracle);
        console.log("whitelist:    ", inputs.whitelist);
    }

    function _readInputs() private view returns (Inputs memory inputs) {
        string memory cfg = vm.readFile(CONFIG_PATH);
        string memory contractsCfg = vm.readFile(CONFIG_CONTRACTS_PATH);

        require(vm.keyExistsToml(cfg, ".general.CHAIN_ID_L2"), "CHAIN_ID_L2 is missing from config.toml");
        require(vm.keyExistsToml(cfg, ".contracts.COMMIT_SCALAR"), "COMMIT_SCALAR is missing from config.toml");
        require(vm.keyExistsToml(cfg, ".contracts.BLOB_SCALAR"), "BLOB_SCALAR is missing from config.toml");
        require(vm.keyExistsToml(cfg, ".contracts.PENALTY_FACTOR"), "PENALTY_FACTOR is missing from config.toml");

        inputs.oracle = contractsCfg.readAddress(".L1_GAS_PRICE_ORACLE_ADDR");
        inputs.whitelist = contractsCfg.readAddress(".L2_WHITELIST_ADDR");
        inputs.expectedChainId = cfg.readUint(".general.CHAIN_ID_L2");
        inputs.commitScalar = cfg.readUint(".contracts.COMMIT_SCALAR");
        inputs.blobScalar = cfg.readUint(".contracts.BLOB_SCALAR");
        inputs.penaltyFactor = cfg.readUint(".contracts.PENALTY_FACTOR");

        inputs.productionL1BaseFee = vm.envUint("PRODUCTION_L1_BASE_FEE");
        inputs.productionL1BlobBaseFee = vm.envUint("PRODUCTION_L1_BLOB_BASE_FEE");
        inputs.productionObservedAt = vm.envUint("PRODUCTION_FEE_OBSERVED_AT");
        inputs.maxProductionAge = vm.envUint("MAX_PRODUCTION_FEE_AGE_SECONDS");
        inputs.maxProductionL1BaseFee = vm.envUint("MAX_PRODUCTION_L1_BASE_FEE");
        inputs.maxProductionL1BlobBaseFee = vm.envUint("MAX_PRODUCTION_L1_BLOB_BASE_FEE");
        inputs.feeGuardCompressedBytes = vm.envUint("FEE_GUARD_COMPRESSED_BYTES");
        inputs.maxL1DataFee = vm.envUint("MAX_L1_DATA_FEE_WEI");

        require(inputs.oracle != address(0), "L1_GAS_PRICE_ORACLE_ADDR is zero");
        require(inputs.whitelist != address(0), "L2_WHITELIST_ADDR is zero");
        require(inputs.expectedChainId != 0, "CHAIN_ID_L2 is zero");
        require(inputs.productionL1BaseFee != 0, "PRODUCTION_L1_BASE_FEE is zero");
        require(inputs.productionL1BlobBaseFee != 0, "PRODUCTION_L1_BLOB_BASE_FEE is zero");
        require(inputs.productionObservedAt != 0, "PRODUCTION_FEE_OBSERVED_AT is zero");
        require(inputs.maxProductionAge != 0, "MAX_PRODUCTION_FEE_AGE_SECONDS is zero");
        require(inputs.maxProductionL1BaseFee != 0, "MAX_PRODUCTION_L1_BASE_FEE is zero");
        require(inputs.maxProductionL1BlobBaseFee != 0, "MAX_PRODUCTION_L1_BLOB_BASE_FEE is zero");
        require(inputs.feeGuardCompressedBytes != 0, "FEE_GUARD_COMPRESSED_BYTES is zero");
        require(inputs.maxL1DataFee != 0, "MAX_L1_DATA_FEE_WEI is zero");
        require(inputs.commitScalar != 0, "COMMIT_SCALAR is zero");
        require(inputs.blobScalar != 0, "BLOB_SCALAR is zero");
        require(inputs.penaltyFactor != 0, "PENALTY_FACTOR is zero");

        require(
            inputs.productionL1BaseFee <= inputs.maxProductionL1BaseFee,
            "PRODUCTION_L1_BASE_FEE exceeds operator cap"
        );
        require(
            inputs.productionL1BlobBaseFee <= inputs.maxProductionL1BlobBaseFee,
            "PRODUCTION_L1_BLOB_BASE_FEE exceeds operator cap"
        );
        require(inputs.productionObservedAt <= block.timestamp, "production observation is in the future");
        require(
            block.timestamp - inputs.productionObservedAt <= inputs.maxProductionAge,
            "production dynamic fee observation is stale"
        );
    }

    function _preflightCommon(Inputs memory inputs, L1GasPriceOracle oracle) private view {
        require(block.chainid == inputs.expectedChainId, "unexpected L2 chain ID");
        require(inputs.oracle.code.length != 0, "L1_GAS_PRICE_ORACLE_ADDR has no code");
        require(inputs.whitelist.code.length != 0, "L2_WHITELIST_ADDR has no code");
        require(address(oracle.whitelist()) == inputs.whitelist, "oracle uses unexpected whitelist");
        require(oracle.isGalileo(), "Galileo fee formula is not active");
        require(oracle.whitelist().isSenderAllowed(oracle.owner()), "oracle owner is not whitelisted");
        _requireFeePathWithinCap(inputs, oracle);
    }

    function _requireMigrationDynamic(L1GasPriceOracle oracle) private view {
        require(oracle.l1BaseFee() == MIGRATION_L1_BASE_FEE, "migration l1BaseFee verification failed");
        require(oracle.l1BlobBaseFee() == MIGRATION_L1_BLOB_BASE_FEE, "migration l1BlobBaseFee verification failed");
    }

    function _requireFeePathWithinCap(Inputs memory inputs, L1GasPriceOracle oracle) private view {
        uint256 currentPenaltyFactor = oracle.penaltyFactor();
        require(currentPenaltyFactor != 0, "current penalty factor is zero");

        uint256 s0 = _calculateGalileoFee(
            oracle.l1BaseFee(),
            oracle.l1BlobBaseFee(),
            oracle.commitScalar(),
            oracle.blobScalar(),
            currentPenaltyFactor,
            inputs.feeGuardCompressedBytes
        );
        uint256 s1 = _calculateGalileoFee(
            MIGRATION_L1_BASE_FEE,
            MIGRATION_L1_BLOB_BASE_FEE,
            oracle.commitScalar(),
            oracle.blobScalar(),
            currentPenaltyFactor,
            inputs.feeGuardCompressedBytes
        );
        uint256 s2 = _calculateGalileoFee(
            MIGRATION_L1_BASE_FEE,
            MIGRATION_L1_BLOB_BASE_FEE,
            inputs.commitScalar,
            oracle.blobScalar(),
            currentPenaltyFactor,
            inputs.feeGuardCompressedBytes
        );
        uint256 s3 = _calculateGalileoFee(
            MIGRATION_L1_BASE_FEE,
            MIGRATION_L1_BLOB_BASE_FEE,
            inputs.commitScalar,
            inputs.blobScalar,
            currentPenaltyFactor,
            inputs.feeGuardCompressedBytes
        );
        uint256 s4 = _calculateGalileoFee(
            MIGRATION_L1_BASE_FEE,
            MIGRATION_L1_BLOB_BASE_FEE,
            inputs.commitScalar,
            inputs.blobScalar,
            inputs.penaltyFactor,
            inputs.feeGuardCompressedBytes
        );
        uint256 production = _calculateGalileoFee(
            inputs.productionL1BaseFee,
            inputs.productionL1BlobBaseFee,
            inputs.commitScalar,
            inputs.blobScalar,
            inputs.penaltyFactor,
            inputs.feeGuardCompressedBytes
        );

        require(s0 <= inputs.maxL1DataFee, "current L1 data fee exceeds operator cap");
        require(s1 <= inputs.maxL1DataFee, "migration L1 data fee exceeds operator cap");
        require(s2 <= inputs.maxL1DataFee, "commit transition L1 data fee exceeds operator cap");
        require(s3 <= inputs.maxL1DataFee, "blob transition L1 data fee exceeds operator cap");
        require(s4 <= inputs.maxL1DataFee, "final L1 data fee exceeds operator cap");
        require(production <= inputs.maxL1DataFee, "production candidate L1 data fee exceeds operator cap");
    }

    function _calculateGalileoFee(
        uint256 l1BaseFee,
        uint256 l1BlobBaseFee,
        uint256 commitScalar,
        uint256 blobScalar,
        uint256 penaltyFactor,
        uint256 compressedBytes
    ) internal pure returns (uint256) {
        require(penaltyFactor != 0, "fee path penalty factor is zero");
        uint256 baseTerm = (commitScalar * l1BaseFee + blobScalar * l1BlobBaseFee) * compressedBytes;
        uint256 penaltyTerm = (baseTerm * compressedBytes) / penaltyFactor;
        return (baseTerm + penaltyTerm) / 1e9;
    }

    function _printState(Inputs memory inputs, L1GasPriceOracle oracle) private view {
        address owner = oracle.owner();

        console.log("chain ID:                         ", block.chainid);
        console.log("oracle:                           ", inputs.oracle);
        console.log("oracle owner:                     ", owner);
        console.log("whitelist:                        ", inputs.whitelist);
        console.log("owner is whitelisted:             ", oracle.whitelist().isSenderAllowed(owner));
        console.log("current l1BaseFee:                ", oracle.l1BaseFee());
        console.log("migration l1BaseFee:              ", MIGRATION_L1_BASE_FEE);
        console.log("production l1BaseFee candidate:   ", inputs.productionL1BaseFee);
        console.log("max production l1BaseFee:         ", inputs.maxProductionL1BaseFee);
        console.log("current l1BlobBaseFee:            ", oracle.l1BlobBaseFee());
        console.log("migration l1BlobBaseFee:          ", MIGRATION_L1_BLOB_BASE_FEE);
        console.log("production l1BlobBaseFee candidate:", inputs.productionL1BlobBaseFee);
        console.log("max production l1BlobBaseFee:     ", inputs.maxProductionL1BlobBaseFee);
        console.log("production candidate observed at: ", inputs.productionObservedAt);
        console.log("latest block timestamp:           ", block.timestamp);
        console.log("max production age seconds:       ", inputs.maxProductionAge);
        console.log("fee guard compressed bytes:       ", inputs.feeGuardCompressedBytes);
        console.log("max L1 data fee wei:              ", inputs.maxL1DataFee);
        console.log(
            "current tuple guarded L1 fee:       ",
            _calculateGalileoFee(
                oracle.l1BaseFee(),
                oracle.l1BlobBaseFee(),
                oracle.commitScalar(),
                oracle.blobScalar(),
                oracle.penaltyFactor(),
                inputs.feeGuardCompressedBytes
            )
        );
        console.log(
            "migration tuple guarded L1 fee:     ",
            _calculateGalileoFee(
                MIGRATION_L1_BASE_FEE,
                MIGRATION_L1_BLOB_BASE_FEE,
                oracle.commitScalar(),
                oracle.blobScalar(),
                oracle.penaltyFactor(),
                inputs.feeGuardCompressedBytes
            )
        );
        console.log(
            "commit transition guarded L1 fee:  ",
            _calculateGalileoFee(
                MIGRATION_L1_BASE_FEE,
                MIGRATION_L1_BLOB_BASE_FEE,
                inputs.commitScalar,
                oracle.blobScalar(),
                oracle.penaltyFactor(),
                inputs.feeGuardCompressedBytes
            )
        );
        console.log(
            "blob transition guarded L1 fee:    ",
            _calculateGalileoFee(
                MIGRATION_L1_BASE_FEE,
                MIGRATION_L1_BLOB_BASE_FEE,
                inputs.commitScalar,
                inputs.blobScalar,
                oracle.penaltyFactor(),
                inputs.feeGuardCompressedBytes
            )
        );
        console.log(
            "final tuple guarded L1 fee:         ",
            _calculateGalileoFee(
                MIGRATION_L1_BASE_FEE,
                MIGRATION_L1_BLOB_BASE_FEE,
                inputs.commitScalar,
                inputs.blobScalar,
                inputs.penaltyFactor,
                inputs.feeGuardCompressedBytes
            )
        );
        console.log(
            "production candidate guarded L1 fee:",
            _calculateGalileoFee(
                inputs.productionL1BaseFee,
                inputs.productionL1BlobBaseFee,
                inputs.commitScalar,
                inputs.blobScalar,
                inputs.penaltyFactor,
                inputs.feeGuardCompressedBytes
            )
        );
        console.log("current commitScalar:             ", oracle.commitScalar());
        console.log("target commitScalar:              ", inputs.commitScalar);
        console.log("current blobScalar:               ", oracle.blobScalar());
        console.log("target blobScalar:                ", inputs.blobScalar);
        console.log("current penaltyFactor:            ", oracle.penaltyFactor());
        console.log("target penaltyFactor:             ", inputs.penaltyFactor);
    }
}
