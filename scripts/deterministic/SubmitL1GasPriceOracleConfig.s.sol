// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L1GasPriceOracle} from "../../src/L2/predeploys/L1GasPriceOracle.sol";

import {CONFIG_PATH, CONFIG_CONTRACTS_PATH} from "./Constants.sol";

/// @notice Applies the fixed migration fee pair and three static Galileo fee
///         parameters transaction by transaction.
/// @dev The dynamic pair is set to 1/1 only for the isolated maintenance
///      transition. The external fee-oracle signer replaces it after handoff.
contract SubmitL1GasPriceOracleConfig is Script {
    using stdToml for string;

    uint256 private constant MIGRATION_L1_BASE_FEE = 1;
    uint256 private constant MIGRATION_L1_BLOB_BASE_FEE = 1;

    struct Inputs {
        address oracle;
        uint256 expectedChainId;
        uint256 commitScalar;
        uint256 blobScalar;
        uint256 penaltyFactor;
    }

    /// @dev The old all-at-once entrypoint is intentionally disabled. The shell
    ///      orchestrator calls one mutating entrypoint at a time and performs a
    ///      separate RPC readback before it permits the next transaction.
    function run() external pure {
        revert("unsafe run() disabled; use migration step entrypoints");
    }

    function dryRun() external view {
        Inputs memory inputs = _readInputs();
        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflightCommon(inputs, oracle);

        console.log("");
        console.log("L1GasPriceOracle migration dry run");
        _printState(inputs, oracle);
    }

    function setMigrationDynamic() external {
        (, L1GasPriceOracle oracle, uint256 ownerPrivateKey) = _prepareOwnerStep();
        address signer = vm.addr(ownerPrivateKey);
        require(oracle.whitelist().isSenderAllowed(signer), "oracle owner is not whitelisted for dynamic update");

        console.log("step 1/4: set fixed migration dynamic fee pair to 1/1");
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

        console.log("signer:       ", signer);
        console.log("oracle:       ", inputs.oracle);
    }

    function _readInputs() private view returns (Inputs memory inputs) {
        string memory cfg = vm.readFile(CONFIG_PATH);
        string memory contractsCfg = vm.readFile(CONFIG_CONTRACTS_PATH);

        require(vm.keyExistsToml(cfg, ".general.CHAIN_ID_L2"), "CHAIN_ID_L2 is missing from config.toml");
        require(vm.keyExistsToml(cfg, ".contracts.COMMIT_SCALAR"), "COMMIT_SCALAR is missing from config.toml");
        require(vm.keyExistsToml(cfg, ".contracts.BLOB_SCALAR"), "BLOB_SCALAR is missing from config.toml");
        require(vm.keyExistsToml(cfg, ".contracts.PENALTY_FACTOR"), "PENALTY_FACTOR is missing from config.toml");

        inputs.oracle = contractsCfg.readAddress(".L1_GAS_PRICE_ORACLE_ADDR");
        inputs.expectedChainId = cfg.readUint(".general.CHAIN_ID_L2");
        inputs.commitScalar = cfg.readUint(".contracts.COMMIT_SCALAR");
        inputs.blobScalar = cfg.readUint(".contracts.BLOB_SCALAR");
        inputs.penaltyFactor = cfg.readUint(".contracts.PENALTY_FACTOR");

        require(inputs.oracle != address(0), "L1_GAS_PRICE_ORACLE_ADDR is zero");
        require(inputs.expectedChainId != 0, "CHAIN_ID_L2 is zero");
        require(inputs.commitScalar != 0, "COMMIT_SCALAR is zero");
        require(inputs.blobScalar != 0, "BLOB_SCALAR is zero");
        require(inputs.penaltyFactor != 0, "PENALTY_FACTOR is zero");
    }

    function _preflightCommon(Inputs memory inputs, L1GasPriceOracle oracle) private view {
        require(block.chainid == inputs.expectedChainId, "unexpected L2 chain ID");
        require(inputs.oracle.code.length != 0, "L1_GAS_PRICE_ORACLE_ADDR has no code");
        require(oracle.isGalileo(), "Galileo fee formula is not active");
    }

    function _requireMigrationDynamic(L1GasPriceOracle oracle) private view {
        require(oracle.l1BaseFee() == MIGRATION_L1_BASE_FEE, "migration l1BaseFee verification failed");
        require(oracle.l1BlobBaseFee() == MIGRATION_L1_BLOB_BASE_FEE, "migration l1BlobBaseFee verification failed");
    }

    function _printState(Inputs memory inputs, L1GasPriceOracle oracle) private view {
        address owner = oracle.owner();

        _logUint("chain ID:                         ", block.chainid);
        console.log("oracle:                           ", inputs.oracle);
        console.log("oracle owner:                     ", owner);
        _logUint("current l1BaseFee:                ", oracle.l1BaseFee());
        _logUint("migration l1BaseFee:              ", MIGRATION_L1_BASE_FEE);
        _logUint("current l1BlobBaseFee:            ", oracle.l1BlobBaseFee());
        _logUint("migration l1BlobBaseFee:          ", MIGRATION_L1_BLOB_BASE_FEE);
        _logUint("current commitScalar:             ", oracle.commitScalar());
        _logUint("target commitScalar:              ", inputs.commitScalar);
        _logUint("current blobScalar:               ", oracle.blobScalar());
        _logUint("target blobScalar:                ", inputs.blobScalar);
        _logUint("current penaltyFactor:            ", oracle.penaltyFactor());
        _logUint("target penaltyFactor:             ", inputs.penaltyFactor);
    }

    function _logUint(string memory label, uint256 value) private view {
        console.log(string.concat(label, vm.toString(value)));
    }
}
