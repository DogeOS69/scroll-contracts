// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L1GasPriceOracle} from "../../src/L2/predeploys/L1GasPriceOracle.sol";

import {CONFIG_PATH, CONFIG_CONTRACTS_PATH} from "./Constants.sol";

/// @notice Broadcasts owner calls that configure Galileo L1 data fee parameters.
contract SubmitL1GasPriceOracleConfig is Script {
    using stdToml for string;

    struct Inputs {
        address oracle;
        uint256 commitScalar;
        uint256 blobScalar;
        uint256 penaltyFactor;
    }

    function run() external {
        Inputs memory inputs = _readInputs();
        uint256 ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");
        address signer = vm.addr(ownerPrivateKey);

        L1GasPriceOracle oracle = L1GasPriceOracle(inputs.oracle);
        _preflight(inputs, oracle, signer);

        vm.startBroadcast(ownerPrivateKey);

        console.log("");
        console.log("step 1/3: L1GasPriceOracle.setCommitScalar(COMMIT_SCALAR)");
        if (oracle.commitScalar() == inputs.commitScalar) {
            console.log("already set - skipping");
        } else {
            oracle.setCommitScalar(inputs.commitScalar);
        }

        console.log("");
        console.log("step 2/3: L1GasPriceOracle.setBlobScalar(BLOB_SCALAR)");
        if (oracle.blobScalar() == inputs.blobScalar) {
            console.log("already set - skipping");
        } else {
            oracle.setBlobScalar(inputs.blobScalar);
        }

        console.log("");
        console.log("step 3/3: L1GasPriceOracle.setPenaltyFactor(PENALTY_FACTOR)");
        if (oracle.penaltyFactor() == inputs.penaltyFactor) {
            console.log("already set - skipping");
        } else {
            oracle.setPenaltyFactor(inputs.penaltyFactor);
        }

        vm.stopBroadcast();
    }

    function _readInputs() private view returns (Inputs memory inputs) {
        string memory cfg = vm.readFile(CONFIG_PATH);
        string memory contractsCfg = vm.readFile(CONFIG_CONTRACTS_PATH);

        require(vm.keyExistsToml(cfg, ".contracts.COMMIT_SCALAR"), "COMMIT_SCALAR is missing from config.toml");

        inputs.oracle = contractsCfg.readAddress(".L1_GAS_PRICE_ORACLE_ADDR");
        inputs.commitScalar = cfg.readUint(".contracts.COMMIT_SCALAR");
        inputs.blobScalar = cfg.readUint(".contracts.BLOB_SCALAR");
        inputs.penaltyFactor = cfg.readUint(".contracts.PENALTY_FACTOR");

        require(inputs.oracle != address(0), "L1_GAS_PRICE_ORACLE_ADDR is zero");
        require(inputs.commitScalar != 0, "COMMIT_SCALAR is zero");
        require(inputs.blobScalar != 0, "BLOB_SCALAR is zero");
        require(inputs.penaltyFactor != 0, "PENALTY_FACTOR is zero");
    }

    function _preflight(
        Inputs memory inputs,
        L1GasPriceOracle oracle,
        address signer
    ) private view {
        require(inputs.oracle.code.length != 0, "L1_GAS_PRICE_ORACLE_ADDR has no code");

        address owner = oracle.owner();
        require(signer == owner, "OWNER_PRIVATE_KEY does not control L1GasPriceOracle owner");

        console.log("");
        console.log("forge script L1GasPriceOracle config preflight");
        console.log("signer:          ", signer);
        console.log("oracle:          ", inputs.oracle);
        console.log("oracle owner:    ", owner);
        console.log("commitScalar:    ", oracle.commitScalar());
        console.log("target commit:   ", inputs.commitScalar);
        console.log("blobScalar:      ", oracle.blobScalar());
        console.log("target blob:     ", inputs.blobScalar);
        console.log("penaltyFactor:   ", oracle.penaltyFactor());
        console.log("target penalty:  ", inputs.penaltyFactor);
    }
}
