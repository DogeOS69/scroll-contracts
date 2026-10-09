// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenerateGenesis} from "../../scripts/deterministic/GenerateGenesis.s.sol";

contract RethGenesisHarness is GenerateGenesis {
    function setTimestampConfig(string memory input) external returns (uint256) {
        cfg = input;
        GENESIS_TIMESTAMP = readGenesisTimestamp();
        return GENESIS_TIMESTAMP;
    }

    function exportGenesis(string memory allocPath, string memory outputPath) external {
        CHAIN_ID_L1 = 111111;
        CHAIN_ID_L2 = 938471;
        BASE_FEE_PER_GAS = 1000000000;
        GENESIS_GAS_LIMIT = 30000000;
        SYSTEM_CONFIG_PROXY_ADDR = address(0x1234);
        L1_MESSAGE_QUEUE_V1_PROXY_ADDR = address(0x1111);
        L1_MESSAGE_QUEUE_V2_PROXY_ADDR = address(0x2222);
        L1_SCROLL_CHAIN_PROXY_ADDR = address(0x3333);
        L2_SYSTEM_CONFIG_PROXY_ADDR = address(0x4444);
        L2_TX_FEE_VAULT_ADDR = 0x5300000000000000000000000000000000000005;

        // Exercise Foundry's actual alloc encoding, including a balance beyond u64.
        vm.deal(address(0x1234), 2**247);
        vm.etch(address(0x1234), hex"60006000");
        vm.store(address(0x1234), bytes32(uint256(1)), bytes32(uint256(42)));
        setBlockHashHistory();
        vm.dumpState(allocPath);
        generateGenesisJson(allocPath, outputPath);
    }
}

contract GenerateGenesisTest is Test {
    function testGenesisTimestampConfig() public {
        RethGenesisHarness harness = new RethGenesisHarness();
        assertEq(harness.setTimestampConfig("[genesis]\nTIMESTAMP = 1760027426\n"), 1760027426);
        assertEq(harness.setTimestampConfig("[genesis]\nTIMESTAMP = 0\n"), 0);
        assertEq(harness.setTimestampConfig('[genesis]\nTIMESTAMP = "18446744073709551615"\n'), type(uint64).max);
        // Re-reading an older config resets to zero, not a previous configured value.
        assertEq(harness.setTimestampConfig("[genesis]\n"), 0);
    }

    function testGenesisTimestampRejectsOverflow() public {
        RethGenesisHarness harness = new RethGenesisHarness();
        vm.expectRevert("invalid genesis.TIMESTAMP");
        harness.setTimestampConfig('[genesis]\nTIMESTAMP = "18446744073709551616"\n');
    }

    function testGenesisTimestampRejectsNegative() public {
        RethGenesisHarness harness = new RethGenesisHarness();
        vm.expectRevert();
        harness.setTimestampConfig("[genesis]\nTIMESTAMP = -1\n");
    }

    function testGenesisTimestampRejectsMalformed() public {
        RethGenesisHarness harness = new RethGenesisHarness();
        vm.expectRevert();
        harness.setTimestampConfig('[genesis]\nTIMESTAMP = "not-a-timestamp"\n');
    }

    function testRethGenesisSerialization() public {
        string[] memory commands = new string[](2);
        commands[0] = "mktemp";
        commands[1] = "-d";
        string memory directory = string(vm.ffi(commands));
        string memory allocPath = string.concat(directory, "/alloc.json");
        string memory outputPath = string.concat(directory, "/genesis.json");

        RethGenesisHarness harness = new RethGenesisHarness();
        harness.setTimestampConfig("[genesis]\nTIMESTAMP = 1760027426\n");
        harness.exportGenesis(allocPath, outputPath);
        string memory genesis = vm.readFile(outputPath);

        assertEq(vm.parseJsonUint(genesis, ".config.chainId"), 938471);
        assertEq(vm.parseJsonUint(genesis, ".config.tsukiTime"), 0);
        assertEq(vm.parseJsonUint(genesis, ".config.scroll.l1Config.l1ChainId"), 111111);
        assertEq(vm.parseJsonUint(genesis, ".config.scroll.l1Config.startL1Block"), 0);
        assertEq(vm.parseJsonUint(genesis, ".config.scroll.l1Config.numL1MessagesPerBlock"), 10);
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.systemContractAddress"), address(0x1234));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.l1MessageQueueAddress"), address(0x1111));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.l1MessageQueueV2Address"), address(0x2222));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.scrollChainAddress"), address(0x3333));
        assertEq(vm.parseJsonAddress(genesis, ".config.scroll.l1Config.l2SystemConfigAddress"), address(0x4444));
        assertEq(vm.parseJsonUint(genesis, ".baseFeePerGas"), 1000000000);
        assertEq(vm.parseJsonUint(genesis, ".gasLimit"), 30000000);
        assertEq(vm.parseJsonUint(genesis, ".timestamp"), 1760027426);
        assertEq(vm.parseJsonBytes(genesis, ".extraData").length, 0);
        assertEq(vm.parseJson(genesis, ".alloc"), vm.parseJson(vm.readFile(allocPath)));
        assertEq(vm.parseJsonUint(genesis, ".config.feynmanTime"), 0);
        string memory history = ".alloc.0x0000f90827f1c53a10cb7a02335b175320002935";
        assertEq(vm.parseJsonUint(genesis, string.concat(history, ".nonce")), 1);
        assertEq(vm.parseJsonUint(genesis, string.concat(history, ".balance")), 0);
        assertEq(vm.parseJsonKeys(genesis, string.concat(history, ".storage")).length, 0);
        assertEq(
            vm.parseJsonBytes(genesis, string.concat(history, ".code")),
            hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500"
        );

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
