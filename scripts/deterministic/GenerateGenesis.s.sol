// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {L1GasPriceOracle} from "../../src/L2/predeploys/L1GasPriceOracle.sol";
import {L2MessageQueue} from "../../src/L2/predeploys/L2MessageQueue.sol";
import {L2TxFeeVault} from "../../src/L2/predeploys/L2TxFeeVault.sol";
import {Whitelist} from "../../src/L2/predeploys/Whitelist.sol";
import {NativeDogeToken} from "../../src/dogeos/NativeDogeToken.sol";
import {WrappedDoge} from "../../src/dogeos/WrappedDoge.sol";
import {DogeOSPredeploy} from "../../src/libraries/constants/DogeOSPredeploy.sol";

import {DETERMINISTIC_DEPLOYMENT_PROXY_ADDR, FEE_VAULT_MIN_WITHDRAW_AMOUNT, GENESIS_ALLOC_JSON_PATH, GENESIS_JSON_PATH, GENESIS_JSON_TEMPLATE_PATH} from "./Constants.sol";
import {DeployScroll} from "./DeployScroll.s.sol";
import {DeterministicDeployment} from "./DeterministicDeployment.sol";

contract GenerateGenesis is DeployScroll {
    /***************
     * Entry point *
     ***************/

    function run() public {
        DeterministicDeployment.initialize(ScriptMode.VerifyConfig);
        predictAllContracts();

        generateGenesisAlloc();
        generateGenesisJson(GENESIS_ALLOC_JSON_PATH, GENESIS_JSON_PATH);

        // clean up temporary files
        vm.removeFile(GENESIS_ALLOC_JSON_PATH);
    }

    /*********************
     * Private functions *
     *********************/

    function generateGenesisAlloc() private {
        if (vm.exists(GENESIS_ALLOC_JSON_PATH)) {
            vm.removeFile(GENESIS_ALLOC_JSON_PATH);
        }

        // Scroll predeploys
        setL2MessageQueue();
        setL1GasPriceOracle();
        setL2Whitelist();
        setL2Weth();
        setL2FeeVault();
        setL2NativeDogeToken();

        // other predeploys
        setDeterministicDeploymentProxy();

        // reset sender
        vm.resetNonce(msg.sender);

        // prefunded accounts
        setL2DogeOsMessenger();
        setL2Deployer();

        // write to file
        vm.dumpState(GENESIS_ALLOC_JSON_PATH);
        sortJsonByKeys(GENESIS_ALLOC_JSON_PATH);
    }

    function setL2MessageQueue() internal {
        address predeployAddr = tryGetOverride("L2_MESSAGE_QUEUE");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        L2MessageQueue _queue = new L2MessageQueue(DEPLOYER_ADDR);
        vm.etch(predeployAddr, address(_queue).code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000052";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_queue), _ownerSlot));

        // reset so its not included state dump
        vm.etch(address(_queue), "");
        vm.resetNonce(address(_queue));
    }

    function setL1GasPriceOracle() internal {
        address predeployAddr = tryGetOverride("L1_GAS_PRICE_ORACLE");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        L1GasPriceOracle _oracle = new L1GasPriceOracle(DEPLOYER_ADDR);
        vm.etch(predeployAddr, address(_oracle).code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_oracle), _ownerSlot));

        bytes32 _isCurieSlot = hex"0000000000000000000000000000000000000000000000000000000000000008";
        vm.store(predeployAddr, _isCurieSlot, bytes32(uint256(1)));

        // Since isGalileo is active from genesis, Galileo's static fee parameters
        // must be initialized at genesis too. penaltyFactor is also the Galileo
        // fee divisor, so it must be non-zero before initializeL1GasPriceOracle.
        bytes32 _commitScalarSlot = hex"0000000000000000000000000000000000000000000000000000000000000006";
        vm.store(predeployAddr, _commitScalarSlot, bytes32(COMMIT_SCALAR));

        bytes32 _blobScalarSlot = hex"0000000000000000000000000000000000000000000000000000000000000007";
        vm.store(predeployAddr, _blobScalarSlot, bytes32(BLOB_SCALAR));

        bytes32 _penaltyFactorSlot = hex"000000000000000000000000000000000000000000000000000000000000000a";
        vm.store(predeployAddr, _penaltyFactorSlot, bytes32(PENALTY_FACTOR));

        bytes32 _isFeynmanSlot = hex"000000000000000000000000000000000000000000000000000000000000000b";
        vm.store(predeployAddr, _isFeynmanSlot, bytes32(uint256(1)));

        bytes32 _isGalileoSlot = hex"000000000000000000000000000000000000000000000000000000000000000c";
        vm.store(predeployAddr, _isGalileoSlot, bytes32(uint256(1)));

        // reset so its not included state dump
        vm.etch(address(_oracle), "");
        vm.resetNonce(address(_oracle));
    }

    function setL2Whitelist() internal {
        address predeployAddr = tryGetOverride("L2_WHITELIST");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        Whitelist _whitelist = new Whitelist(DEPLOYER_ADDR);
        vm.etch(predeployAddr, address(_whitelist).code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_whitelist), _ownerSlot));

        // reset so its not included state dump
        vm.etch(address(_whitelist), "");
        vm.resetNonce(address(_whitelist));
    }

    function setL2Weth() internal {
        address predeployAddr = tryGetOverride("L2_WDOGE");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        WrappedDoge _wdoge = new WrappedDoge();
        vm.etch(predeployAddr, address(_wdoge).code);

        // set storage
        bytes32 _nameSlot = hex"0000000000000000000000000000000000000000000000000000000000000003";
        vm.store(predeployAddr, _nameSlot, vm.load(address(_wdoge), _nameSlot));

        bytes32 _symbolSlot = hex"0000000000000000000000000000000000000000000000000000000000000004";
        vm.store(predeployAddr, _symbolSlot, vm.load(address(_wdoge), _symbolSlot));

        // reset so its not included state dump
        vm.etch(address(_wdoge), "");
        vm.resetNonce(address(_wdoge));
    }

    function setL2FeeVault() internal {
        address predeployAddr = tryGetOverride("L2_TX_FEE_VAULT");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        // note: the genesis-time messenger/recipient wiring is temporary. The messenger
        // no longer accepts the vault as a sender, so fee withdrawals revert (fail-closed)
        // until DeployScroll's initializeL2TxFeeVault() repoints the vault at the
        // FeeVaultMoatAdapter and sets the Dogecoin recipient.
        address _vaultAddr;
        vm.prank(DEPLOYER_ADDR);
        L2TxFeeVault _vault = new L2TxFeeVault(DEPLOYER_ADDR, L1_FEE_VAULT_ADDR, FEE_VAULT_MIN_WITHDRAW_AMOUNT);
        vm.prank(DEPLOYER_ADDR);
        _vault.updateMessenger(L2_DOGEOS_MESSENGER_PROXY_ADDR);
        _vaultAddr = address(_vault);

        vm.etch(predeployAddr, _vaultAddr.code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.store(predeployAddr, _ownerSlot, vm.load(_vaultAddr, _ownerSlot));

        bytes32 _minWithdrawAmountSlot = hex"0000000000000000000000000000000000000000000000000000000000000001";
        vm.store(predeployAddr, _minWithdrawAmountSlot, vm.load(_vaultAddr, _minWithdrawAmountSlot));

        bytes32 _messengerSlot = hex"0000000000000000000000000000000000000000000000000000000000000002";
        vm.store(predeployAddr, _messengerSlot, vm.load(_vaultAddr, _messengerSlot));

        bytes32 _recipientSlot = hex"0000000000000000000000000000000000000000000000000000000000000003";
        vm.store(predeployAddr, _recipientSlot, vm.load(_vaultAddr, _recipientSlot));

        bytes32 _ETHGatewaySlot = hex"0000000000000000000000000000000000000000000000000000000000000005";
        vm.store(predeployAddr, _ETHGatewaySlot, vm.load(_vaultAddr, _ETHGatewaySlot));

        // reset so its not included state dump
        vm.etch(_vaultAddr, "");
        vm.resetNonce(_vaultAddr);
    }

    function setL2NativeDogeToken() internal {
        address predeployAddr = tryGetOverride("L2_NATIVE_DOGE_TOKEN");

        if (predeployAddr == address(0)) {
            revert("L2_NATIVE_DOGE_TOKEN override missing from config.toml [contracts.overrides]");
        }
        if (predeployAddr != DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN) {
            revert("L2_NATIVE_DOGE_TOKEN override must match DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN");
        }

        NativeDogeToken token = new NativeDogeToken(L2_MAX_NATIVE_DOGE_SUPPLY);

        vm.etch(predeployAddr, address(token).code);

        bytes32 totalSupplySlot = bytes32(uint256(0));
        vm.store(predeployAddr, totalSupplySlot, vm.load(address(token), totalSupplySlot));

        vm.etch(address(token), "");
        vm.resetNonce(address(token));
    }

    function setDeterministicDeploymentProxy() internal {
        bytes
            memory code = hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
        vm.etch(DETERMINISTIC_DEPLOYMENT_PROXY_ADDR, code);
    }

    function setL2DogeOsMessenger() internal {
        vm.deal(L2_DOGEOS_MESSENGER_PROXY_ADDR, L2_DOGEOS_MESSENGER_INITIAL_BALANCE);
    }

    function setL2Deployer() internal {
        vm.deal(DEPLOYER_ADDR, L2_DEPLOYER_INITIAL_BALANCE);
    }

    function generateGenesisJson(string memory allocPath, string memory outputPath) internal {
        // The Docker entrypoint wraps this JSON in YAML for the Kubernetes ConfigMap.
        vm.writeFile(outputPath, vm.readFile(GENESIS_JSON_TEMPLATE_PATH));

        // Chain IDs and L1 block/message counts are JSON numbers. Addresses and
        // header quantities are explicitly quoted JSON strings, avoiding writeJson's
        // implicit value parsing.
        vm.writeJson(vm.toString(CHAIN_ID_L2), outputPath, ".config.chainId");
        writeGenesisString(vm.toString(bytes32(vm.unixTime() / 1000)), outputPath, ".timestamp");
        writeGenesisString(vm.toString(bytes32(BASE_FEE_PER_GAS)), outputPath, ".baseFeePerGas");

        writeGenesisString(vm.toString(L2_TX_FEE_VAULT_ADDR), outputPath, ".config.scroll.feeVaultAddress");
        vm.writeJson(vm.toString(CHAIN_ID_L1), outputPath, ".config.scroll.l1Config.l1ChainId");
        writeGenesisString(
            vm.toString(SYSTEM_CONFIG_PROXY_ADDR),
            outputPath,
            ".config.scroll.l1Config.systemContractAddress"
        );
        writeGenesisString(
            vm.toString(L1_MESSAGE_QUEUE_V1_PROXY_ADDR),
            outputPath,
            ".config.scroll.l1Config.l1MessageQueueAddress"
        );
        writeGenesisString(
            vm.toString(L1_MESSAGE_QUEUE_V2_PROXY_ADDR),
            outputPath,
            ".config.scroll.l1Config.l1MessageQueueV2Address"
        );
        writeGenesisString(
            vm.toString(L1_SCROLL_CHAIN_PROXY_ADDR),
            outputPath,
            ".config.scroll.l1Config.scrollChainAddress"
        );
        writeGenesisString(
            vm.toString(L2_SYSTEM_CONFIG_PROXY_ADDR),
            outputPath,
            ".config.scroll.l1Config.l2SystemConfigAddress"
        );

        // Preserve the state dump's balances, bytecode and storage without re-encoding.
        vm.writeJson(vm.readFile(allocPath), outputPath, ".alloc");
    }

    function writeGenesisString(
        string memory value,
        string memory outputPath,
        string memory key
    ) private {
        // Callers only pass hex-encoded addresses/quantities, which need no JSON escaping.
        vm.writeJson(string.concat('"', value, '"'), outputPath, key);
    }

    /// @notice Sorts the allocs by address
    // source: https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/scripts/L2Genesis.s.sol
    function sortJsonByKeys(string memory _path) private {
        string[] memory commands = new string[](3);
        commands[0] = "/bin/bash";
        commands[1] = "-c";
        commands[2] = string.concat("cat <<< $(jq -S '.' ", _path, ") > ", _path);
        vm.ffi(commands);
    }
}
