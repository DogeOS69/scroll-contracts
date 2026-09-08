// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {console} from "forge-std/console.sol";

import {CONFIG_PATH, CONFIG_CONTRACTS_PATH, CONFIG_CONTRACTS_TEMPLATE_PATH} from "./Constants.sol";
import {NativeDogeSupplyConfig} from "./NativeDogeSupplyConfig.sol";

/// @notice Configuration allows inheriting contracts to read the TOML configuration file.
abstract contract Configuration is NativeDogeSupplyConfig {
    using stdToml for string;

    /*******************
     * State variables *
     *******************/

    string internal cfg;
    string internal contractsCfg;

    /****************************
     * Configuration parameters *
     ****************************/

    // general
    string internal L1_RPC_ENDPOINT;
    string internal L2_RPC_ENDPOINT;

    string internal CHAIN_NAME_L1;
    string internal CHAIN_NAME_L2;
    uint64 internal CHAIN_ID_L1;
    uint64 internal CHAIN_ID_L2;

    uint256 internal MAX_TX_IN_CHUNK;
    uint256 internal MAX_BLOCK_IN_CHUNK;
    uint256 internal MAX_BATCH_IN_BUNDLE;
    uint256 internal MAX_L1_MESSAGE_GAS_LIMIT;
    uint256 internal FINALIZE_BATCH_DEADLINE_SEC;
    uint256 internal RELAY_MESSAGE_DEADLINE_SEC;

    uint256 internal L1_CONTRACT_DEPLOYMENT_BLOCK;

    bool internal TEST_ENV_MOCK_FINALIZE_ENABLED;
    uint256 internal TEST_ENV_MOCK_FINALIZE_TIMEOUT_SEC;

    // accounts
    uint256 internal DEPLOYER_PRIVATE_KEY;

    address internal DEPLOYER_ADDR;
    address internal constant L1_GAS_ORACLE_SENDER_ADDR = address(0);
    address internal L2_GAS_ORACLE_SENDER_ADDR;

    address internal OWNER_ADDR;

    address internal constant L2GETH_SIGNER_ADDRESS = address(0);

    // genesis
    uint256 internal L2_MAX_ETH_SUPPLY;
    uint256 internal L2_MAX_NATIVE_DOGE_SUPPLY;
    uint256 internal L2_DEPLOYER_INITIAL_BALANCE;
    uint256 internal L2_SCROLL_MESSENGER_INITIAL_BALANCE;
    uint256 internal L2_DOGEOS_MESSENGER_INITIAL_BALANCE;
    uint256 internal BASE_FEE_PER_GAS;

    // contracts
    string internal DEPLOYMENT_SALT;
    address internal L1_FEE_VAULT_ADDR;
    address internal L2_BRIDGE_FEE_RECIPIENT_ADDR;
    // Dogecoin P2PKH hash160 (encoded as an address) that receives fee vault withdrawals.
    address internal FEE_VAULT_DOGE_RECIPIENT_ADDR;

    // bridge fees
    uint256 internal DEPOSIT_FEE;
    uint256 internal WITHDRAWAL_FEE;
    uint256 internal MIN_WITHDRAWAL_AMOUNT;

    // coordinator
    string internal CHUNK_COLLECTION_TIME_SEC;
    string internal BATCH_COLLECTION_TIME_SEC;
    string internal BUNDLE_COLLECTION_TIME_SEC;
    string internal constant COORDINATOR_JWT_SECRET_KEY = "dogeos-coordinator-jwt-secret";

    // frontend
    string internal EXTERNAL_RPC_URI_L1;
    string internal EXTERNAL_RPC_URI_L2;
    string internal BRIDGE_API_URI;
    string internal EXTERNAL_EXPLORER_URI_L1;
    string internal EXTERNAL_EXPLORER_URI_L2;
    string internal GRAFANA_URI;

    // gas price oracle
    uint256 internal COMMIT_SCALAR;
    uint256 internal BLOB_SCALAR;
    uint256 internal SCALAR;
    uint256 internal PENALTY_FACTOR;

    /**********************
     * Internal interface *
     **********************/

    function readConfig() internal {
        if (!vm.exists(CONFIG_CONTRACTS_PATH)) {
            string memory template = vm.readFile(CONFIG_CONTRACTS_TEMPLATE_PATH);
            vm.writeFile(CONFIG_CONTRACTS_PATH, template);
        }

        cfg = vm.readFile(CONFIG_PATH);
        contractsCfg = vm.readFile(CONFIG_CONTRACTS_PATH);

        L1_RPC_ENDPOINT = cfg.readString(".general.L1_RPC_ENDPOINT");
        L2_RPC_ENDPOINT = cfg.readString(".general.L2_RPC_ENDPOINT");

        CHAIN_NAME_L1 = cfg.readString(".general.CHAIN_NAME_L1");
        CHAIN_NAME_L2 = cfg.readString(".general.CHAIN_NAME_L2");
        CHAIN_ID_L1 = uint64(cfg.readUint(".general.CHAIN_ID_L1"));
        CHAIN_ID_L2 = uint64(cfg.readUint(".general.CHAIN_ID_L2"));

        MAX_TX_IN_CHUNK = cfg.readUint(".rollup.MAX_TX_IN_CHUNK");
        MAX_BLOCK_IN_CHUNK = cfg.readUint(".rollup.MAX_BLOCK_IN_CHUNK");
        MAX_BATCH_IN_BUNDLE = cfg.readUint(".rollup.MAX_BATCH_IN_BUNDLE");
        MAX_L1_MESSAGE_GAS_LIMIT = cfg.readUint(".rollup.MAX_L1_MESSAGE_GAS_LIMIT");
        FINALIZE_BATCH_DEADLINE_SEC = cfg.readUint(".rollup.FINALIZE_BATCH_DEADLINE_SEC");
        RELAY_MESSAGE_DEADLINE_SEC = cfg.readUint(".rollup.RELAY_MESSAGE_DEADLINE_SEC");

        L1_CONTRACT_DEPLOYMENT_BLOCK = cfg.readUint(".general.L1_CONTRACT_DEPLOYMENT_BLOCK");

        TEST_ENV_MOCK_FINALIZE_ENABLED = cfg.readBool(".rollup.TEST_ENV_MOCK_FINALIZE_ENABLED");
        TEST_ENV_MOCK_FINALIZE_TIMEOUT_SEC = cfg.readUint(".rollup.TEST_ENV_MOCK_FINALIZE_TIMEOUT_SEC");

        DEPLOYER_PRIVATE_KEY = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));

        if (DEPLOYER_PRIVATE_KEY == uint256(0)) {
            DEPLOYER_PRIVATE_KEY = cfg.readUint(".accounts.DEPLOYER_PRIVATE_KEY");
        }

        DEPLOYER_ADDR = cfg.readAddress(".accounts.DEPLOYER_ADDR");
        L2_GAS_ORACLE_SENDER_ADDR = readL2GasOracleSenderAddress();

        OWNER_ADDR = cfg.readAddress(".accounts.OWNER_ADDR");

        L2_MAX_NATIVE_DOGE_SUPPLY = readL2MaxNativeDogeSupply(cfg);
        L2_MAX_ETH_SUPPLY = L2_MAX_NATIVE_DOGE_SUPPLY;
        L2_DEPLOYER_INITIAL_BALANCE = cfg.readUint(".genesis.L2_DEPLOYER_INITIAL_BALANCE");
        BASE_FEE_PER_GAS = cfg.readUint(".genesis.BASE_FEE_PER_GAS");

        L2_DOGEOS_MESSENGER_INITIAL_BALANCE = L2_MAX_NATIVE_DOGE_SUPPLY - L2_DEPLOYER_INITIAL_BALANCE;
        L2_SCROLL_MESSENGER_INITIAL_BALANCE = L2_DOGEOS_MESSENGER_INITIAL_BALANCE;

        DEPLOYMENT_SALT = cfg.readString(".contracts.DEPLOYMENT_SALT");

        L1_FEE_VAULT_ADDR = cfg.readAddress(".contracts.L1_FEE_VAULT_ADDR");

        L2_BRIDGE_FEE_RECIPIENT_ADDR = cfg.readAddress(".contracts.L2_BRIDGE_FEE_RECIPIENT_ADDR");

        // Optional key for older configs; required (notnull) when wiring the fee vault
        // to the FeeVaultMoatAdapter during initialization.
        if (vm.keyExistsToml(cfg, ".contracts.FEE_VAULT_DOGE_RECIPIENT_ADDR")) {
            FEE_VAULT_DOGE_RECIPIENT_ADDR = cfg.readAddress(".contracts.FEE_VAULT_DOGE_RECIPIENT_ADDR");
        }

        DEPOSIT_FEE = cfg.readUint(".contracts.DEPOSIT_FEE");
        WITHDRAWAL_FEE = cfg.readUint(".contracts.WITHDRAWAL_FEE");
        MIN_WITHDRAWAL_AMOUNT = cfg.readUint(".contracts.MIN_WITHDRAWAL_AMOUNT");

        COMMIT_SCALAR = cfg.readUint(".contracts.COMMIT_SCALAR");
        BLOB_SCALAR = cfg.readUint(".contracts.BLOB_SCALAR");
        SCALAR = cfg.readUint(".contracts.SCALAR");
        PENALTY_FACTOR = cfg.readUint(".contracts.PENALTY_FACTOR");

        CHUNK_COLLECTION_TIME_SEC = cfg.readString(".coordinator.CHUNK_COLLECTION_TIME_SEC");
        BATCH_COLLECTION_TIME_SEC = cfg.readString(".coordinator.BATCH_COLLECTION_TIME_SEC");
        BUNDLE_COLLECTION_TIME_SEC = cfg.readString(".coordinator.BUNDLE_COLLECTION_TIME_SEC");

        EXTERNAL_RPC_URI_L1 = cfg.readString(".frontend.EXTERNAL_RPC_URI_L1");
        EXTERNAL_RPC_URI_L2 = cfg.readString(".frontend.EXTERNAL_RPC_URI_L2");
        BRIDGE_API_URI = cfg.readString(".frontend.BRIDGE_API_URI");
        EXTERNAL_EXPLORER_URI_L1 = cfg.readString(".frontend.EXTERNAL_EXPLORER_URI_L1");
        EXTERNAL_EXPLORER_URI_L2 = cfg.readString(".frontend.EXTERNAL_EXPLORER_URI_L2");
        GRAFANA_URI = cfg.readString(".frontend.GRAFANA_URI");

        FINALIZE_BATCH_DEADLINE_SEC = cfg.readUint(".rollup.FINALIZE_BATCH_DEADLINE_SEC");
        RELAY_MESSAGE_DEADLINE_SEC = cfg.readUint(".rollup.RELAY_MESSAGE_DEADLINE_SEC");

        runSanityCheck();
    }

    /// @dev Ensure that `addr` is not the zero address.
    ///      This helps catch bugs arising from incorrect deployment order.
    function notnull(address addr) internal pure returns (address) {
        require(addr != address(0), "null address");
        return addr;
    }

    function tryGetOverride(string memory name) internal returns (address) {
        address addr;
        string memory key;
        if (keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked("L1_GAS_TOKEN"))) {
            key = string(abi.encodePacked(".gas-token.", name));
        } else {
            key = string(abi.encodePacked(".contracts.overrides.", name));
        }

        if (!vm.keyExistsToml(cfg, key)) {
            return address(0);
        }

        addr = cfg.readAddress(key);

        if (addr.code.length == 0) {
            (VmSafe.CallerMode callerMode, , ) = vm.readCallers();

            // if we're ready to start broadcasting transactions, then we
            // must ensure that the override contract has been deployed.
            if (callerMode == VmSafe.CallerMode.Broadcast || callerMode == VmSafe.CallerMode.RecurrentBroadcast) {
                revert(
                    string(
                        abi.encodePacked(
                            "[ERROR] override ",
                            name,
                            " = ",
                            vm.toString(addr),
                            " not deployed in broadcast mode"
                        )
                    )
                );
            }
        }

        return addr;
    }

    /*********************
     * Private functions *
     *********************/

    /// @dev Deployment authorizes this service but never signs as it. KMS/HSM
    ///      operators provide only the public address, not an exportable key.
    function readL2GasOracleSenderAddress() internal view returns (address) {
        address sender = cfg.readAddress(".accounts.L2_GAS_ORACLE_SENDER_ADDR");
        require(sender != address(0), "L2_GAS_ORACLE_SENDER_ADDR must not be zero");
        return sender;
    }

    function runSanityCheck() private view {
        verifyAccount("DEPLOYER", DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDR);
    }

    function verifyAccount(
        string memory name,
        uint256 privateKey,
        address addr
    ) private pure {
        if (vm.addr(privateKey) != addr) {
            revert(
                string(
                    abi.encodePacked(
                        "[ERROR] ",
                        name,
                        "_ADDR (",
                        vm.toString(addr),
                        ") does not match ",
                        name,
                        "_PRIVATE_KEY"
                    )
                )
            );
        }
    }
}
