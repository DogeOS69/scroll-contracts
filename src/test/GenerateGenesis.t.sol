// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenerateGenesis} from "../../scripts/deterministic/GenerateGenesis.s.sol";

contract RethGenesisHarness is GenerateGenesis {
    function exportGenesis(string memory allocPath, string memory outputPath) external {
        CHAIN_ID_L1 = 111111;
        CHAIN_ID_L2 = 938471;
        // The scan start must remain zero even for an existing L1 deployment.
        L1_CONTRACT_DEPLOYMENT_BLOCK = 62942942;
        BASE_FEE_PER_GAS = 1000000000;
        SYSTEM_CONFIG_PROXY_ADDR = address(0x1234);
        L1_MESSAGE_QUEUE_V1_PROXY_ADDR = address(0x1111);
        L1_MESSAGE_QUEUE_V2_PROXY_ADDR = address(0x2222);
        L1_SCROLL_CHAIN_PROXY_ADDR = address(0x3333);
        L2_SYSTEM_CONFIG_PROXY_ADDR = address(0x4444);
        L2_TX_FEE_VAULT_ADDR = 0x5300000000000000000000000000000000000005;
        L2GETH_SIGNER_ADDRESS = address(0x5555);

        // Exercise Foundry's actual alloc encoding, including a balance beyond u64.
        vm.deal(address(0x1234), 2**247);
        vm.etch(address(0x1234), hex"60006000");
        vm.store(address(0x1234), bytes32(uint256(1)), bytes32(uint256(42)));
        vm.dumpState(allocPath);
        generateGenesisJson(allocPath, outputPath);
    }
}

contract GenerateGenesisTest is Test {
    function testRethGenesisSerialization() public {
        string[] memory commands = new string[](2);
        commands[0] = "mktemp";
        commands[1] = "-d";
        string memory directory = string(vm.ffi(commands));
        string memory allocPath = string.concat(directory, "/alloc.json");
        string memory outputPath = string.concat(directory, "/genesis.json");

        RethGenesisHarness harness = new RethGenesisHarness();
        harness.exportGenesis(allocPath, outputPath);
        string memory genesis = vm.readFile(outputPath);

        assertEq(vm.parseJsonUint(genesis, ".config.chainId"), 938471);
        assertEq(vm.parseJsonUint(genesis, ".config.scroll.l1Config.l1ChainId"), 111111);
        assertEq(vm.parseJsonUint(genesis, ".config.scroll.l1Config.startL1Block"), 0);
        assertEq(vm.parseJsonUint(genesis, ".config.scroll.l1Config.numL1MessagesPerBlock"), 10);
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.systemContractAddress"), address(0x1234));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.l1MessageQueueAddress"), address(0x1111));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.l1MessageQueueV2Address"), address(0x2222));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.scrollChainAddress"), address(0x3333));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.l2SystemConfigAddress"), address(0x4444));
        assertEq(vm.parseJsonUint(genesis, ".baseFeePerGas"), 1000000000);
        assertEq(vm.parseJsonUint(genesis, ".gasLimit"), 10000000);
        assertEq(vm.parseJsonBytes(genesis, ".extraData").length, 0);
        assertEq(vm.parseJson(genesis, ".alloc"), vm.parseJson(vm.readFile(allocPath)));

        // Foundry's typed JSON readers accept numeric strings too. Check the raw
        // JSON types with jq to catch accidental quoting or double encoding.
        commands = new string[](5);
        commands[0] = "jq";
        commands[1] = "-e";
        commands[2] = "-f";
        commands[3] = "src/test/fixtures/reth-genesis.jq";
        commands[4] = outputPath;
        assertEq(string(vm.ffi(commands)), "true");

        vm.removeFile(allocPath);
        vm.removeFile(outputPath);
        vm.removeDir(directory, false);
    }
}
