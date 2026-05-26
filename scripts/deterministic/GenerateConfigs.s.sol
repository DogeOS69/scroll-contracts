// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {COORDINATOR_API_CONFIG_PATH, COORDINATOR_CONFIG_TEMPLATE_PATH, COORDINATOR_CRON_CONFIG_PATH, FRONTEND_ENV_PATH} from "./Constants.sol";
import {DeployScroll} from "./DeployScroll.s.sol";
import {DeterministicDeployment} from "./DeterministicDeployment.sol";

contract GenerateCoordinatorConfig is DeployScroll {
    /***************
     * Entry point *
     ***************/

    function run() public {
        DeterministicDeployment.initialize(ScriptMode.VerifyConfig);
        predictAllContracts();
        generateCoordinatorConfig(COORDINATOR_API_CONFIG_PATH);
        generateCoordinatorConfig(COORDINATOR_CRON_CONFIG_PATH);
    }

    /*********************
     * Private functions *
     *********************/

    function generateCoordinatorConfig(string memory PATH) private {
        // initialize template file
        if (vm.exists(PATH)) {
            vm.removeFile(PATH);
        }

        string memory template = vm.readFile(COORDINATOR_CONFIG_TEMPLATE_PATH);
        vm.writeFile(PATH, template);

        vm.writeJson(CHUNK_COLLECTION_TIME_SEC, PATH, ".prover_manager.chunk_collection_time_sec");
        vm.writeJson(BATCH_COLLECTION_TIME_SEC, PATH, ".prover_manager.batch_collection_time_sec");
        vm.writeJson(BUNDLE_COLLECTION_TIME_SEC, PATH, ".prover_manager.bundle_collection_time_sec");
        vm.writeJson(vm.toString(CHAIN_ID_L2), PATH, ".l2.chain_id");
        vm.writeJson(L2_RPC_ENDPOINT, PATH, ".l2.l2geth.endpoint");
        vm.writeJson(COORDINATOR_JWT_SECRET_KEY, PATH, ".auth.secret");
    }
}

contract GenerateFrontendConfig is DeployScroll {
    /***************
     * Entry point *
     ***************/

    function run() public {
        DeterministicDeployment.initialize(ScriptMode.VerifyConfig);
        predictAllContracts();

        generateFrontendConfig();
    }

    /*********************
     * Private functions *
     *********************/

    // prettier-ignore
    function generateFrontendConfig() private {
        // use writeFile to start a new file
        vm.writeFile(FRONTEND_ENV_PATH, "REACT_APP_ETH_SYMBOL = \"DOGE\"\n");
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_BASE_CHAIN = \"", CHAIN_NAME_L1, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_ROLLUP = \"", CHAIN_NAME_L2, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_CHAIN_ID_L1 = \"", vm.toString(CHAIN_ID_L1), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_CHAIN_ID_L2 = \"", vm.toString(CHAIN_ID_L2), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_CONNECT_WALLET_PROJECT_ID = \"14efbaafcf5232a47d93a68229b71028\"");

        // API endpoints
        vm.writeLine(FRONTEND_ENV_PATH, "");
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_EXTERNAL_RPC_URI_L1 = \"", EXTERNAL_RPC_URI_L1, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_EXTERNAL_RPC_URI_L2 = \"", EXTERNAL_RPC_URI_L2, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_BRIDGE_API_URI = \"", BRIDGE_API_URI, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_EXTERNAL_EXPLORER_URI_L1 = \"", EXTERNAL_EXPLORER_URI_L1, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_EXTERNAL_EXPLORER_URI_L2 = \"", EXTERNAL_EXPLORER_URI_L2, "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("GRAFANA_URI = \"", GRAFANA_URI, "\""));

        // L1 contracts
        vm.writeLine(FRONTEND_ENV_PATH, "");
        // vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR = \"", vm.toString(L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_ETH_GATEWAY_PROXY_ADDR = \"", vm.toString(L1_ETH_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_GAS_PRICE_ORACLE = \"", vm.toString(L1_GAS_PRICE_ORACLE_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_GATEWAY_ROUTER_PROXY_ADDR = \"", vm.toString(L1_GATEWAY_ROUTER_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_MESSAGE_QUEUE = \"", vm.toString(L1_MESSAGE_QUEUE_V2_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_MESSAGE_QUEUE_WITH_GAS_PRICE_ORACLE = \"", vm.toString(L1_MESSAGE_QUEUE_V2_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_SCROLL_MESSENGER = \"", vm.toString(L1_SCROLL_MESSENGER_PROXY_ADDR), "\""));
        // vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR = \"", vm.toString(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_WETH_GATEWAY_PROXY_ADDR = \"", vm.toString(L1_WETH_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_SCROLL_CHAIN = \"", vm.toString(L1_SCROLL_CHAIN_PROXY_ADDR), "\""));
        //vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_GAS_TOKEN_GATEWAY = \"", vm.toString(L1_GAS_TOKEN_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_WRAPPED_TOKEN_GATEWAY = \"", vm.toString(L1_WRAPPED_TOKEN_GATEWAY_ADDR), "\""));
        //vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_GAS_TOKEN_ADDR = \"", vm.toString(L1_GAS_TOKEN_ADDR), "\""));
        // vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_WETH_ADDR = \"", vm.toString(L1_WETH_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L1_WDOGE_ADDR = \"", vm.toString(L1_WDOGE_ADDR), "\""));

        // L2 contracts
        vm.writeLine(FRONTEND_ENV_PATH, "");
        // vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR = \"", vm.toString(L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L2_ETH_GATEWAY_PROXY_ADDR = \"", vm.toString(L2_ETH_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L2_GATEWAY_ROUTER_PROXY_ADDR = \"", vm.toString(L2_GATEWAY_ROUTER_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L2_SCROLL_MESSENGER = \"", vm.toString(L2_DOGEOS_MESSENGER_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR = \"", vm.toString(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR), "\""));
        vm.writeLine(FRONTEND_ENV_PATH, string.concat("REACT_APP_L2_WETH_GATEWAY_PROXY_ADDR = \"", vm.toString(L2_WETH_GATEWAY_PROXY_ADDR), "\""));

        // custom token gateways (currently not set)
        vm.writeLine(FRONTEND_ENV_PATH, "");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L1_USDC_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L2_USDC_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L1_DAI_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L2_DAI_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L1_LIDO_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L2_LIDO_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L1_PUFFER_GATEWAY_PROXY_ADDR = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L2_PUFFER_GATEWAY_PROXY_ADDR = \"\"");

        // misc
        vm.writeLine(FRONTEND_ENV_PATH, "");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_SCROLL_ORIGINS_NFT = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_SCROLL_ORIGINS_NFT_V2 = \"\"");
        vm.writeLine(FRONTEND_ENV_PATH, "REACT_APP_L1_BATCH_BRIDGE_GATEWAY_PROXY_ADDR = \"\"");
    }
}
