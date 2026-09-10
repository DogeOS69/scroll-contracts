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
    string internal CHAIN_NAME_L1;
    string internal CHAIN_NAME_L2;
    uint64 internal CHAIN_ID_L1;
    uint64 internal CHAIN_ID_L2;

    // accounts
    uint256 internal DEPLOYER_PRIVATE_KEY;

    address internal DEPLOYER_ADDR;
    address internal constant L1_GAS_ORACLE_SENDER_ADDR = address(0);
    address internal L2_GAS_ORACLE_SENDER_ADDR;

    address internal OWNER_ADDR;

    address internal constant L2GETH_SIGNER_ADDRESS = address(0);

    // genesis
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

    // frontend
    string internal EXTERNAL_RPC_URI_L1;
    string internal EXTERNAL_RPC_URI_L2;
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

        CHAIN_NAME_L1 = cfg.readString(".general.CHAIN_NAME_L1");
        CHAIN_NAME_L2 = cfg.readString(".general.CHAIN_NAME_L2");
        CHAIN_ID_L1 = uint64(cfg.readUint(".general.CHAIN_ID_L1"));
        CHAIN_ID_L2 = uint64(cfg.readUint(".general.CHAIN_ID_L2"));

        DEPLOYER_PRIVATE_KEY = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));

        if (DEPLOYER_PRIVATE_KEY == uint256(0)) {
            DEPLOYER_PRIVATE_KEY = cfg.readUint(".accounts.DEPLOYER_PRIVATE_KEY");
        }

        DEPLOYER_ADDR = cfg.readAddress(".accounts.DEPLOYER_ADDR");
        L2_GAS_ORACLE_SENDER_ADDR = readL2GasOracleSenderAddress();

        OWNER_ADDR = cfg.readAddress(".accounts.OWNER_ADDR");

        L2_MAX_NATIVE_DOGE_SUPPLY = readL2MaxNativeDogeSupply(cfg);
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

        EXTERNAL_RPC_URI_L1 = cfg.readString(".frontend.EXTERNAL_RPC_URI_L1");
        EXTERNAL_RPC_URI_L2 = cfg.readString(".frontend.EXTERNAL_RPC_URI_L2");
        EXTERNAL_EXPLORER_URI_L1 = cfg.readString(".frontend.EXTERNAL_EXPLORER_URI_L1");
        EXTERNAL_EXPLORER_URI_L2 = cfg.readString(".frontend.EXTERNAL_EXPLORER_URI_L2");
        GRAFANA_URI = cfg.readString(".frontend.GRAFANA_URI");

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
        string memory key = ".accounts.L2_GAS_ORACLE_SENDER_ADDR";
        string
            memory missingAddressMessage = "Set accounts.L2_GAS_ORACLE_SENDER_ADDR in volume/config.toml to the L2 gas oracle signer address";
        require(vm.keyExistsToml(cfg, key), missingAddressMessage);
        require(bytes(cfg.readString(key)).length != 0, missingAddressMessage);
        address sender = cfg.readAddress(key);
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
