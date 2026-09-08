// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {Configuration} from "../../scripts/deterministic/Configuration.sol";

contract FeeOracleAddressConfigurationHarness is Configuration {
    function readAddress(string memory input) external returns (address) {
        cfg = input;
        return readL2GasOracleSenderAddress();
    }
}

contract FeeOracleAddressConfigurationTest is Test {
    FeeOracleAddressConfigurationHarness private harness;
    address private constant KMS_SENDER = 0xbEEC0A88c46ad59AA82aA0208F914a1ba6b83e5c;

    function setUp() public {
        harness = new FeeOracleAddressConfigurationHarness();
    }

    function testAddressOnlyWithoutPrivateKey() public {
        assertEq(harness.readAddress(addressConfig()), KMS_SENDER);
    }

    function testIgnoresLegacyPrivateKeyAndEnvironment() public {
        vm.setEnv("L2_GAS_ORACLE_SENDER_PRIVATE_KEY", "not-an-exportable-key");
        assertEq(
            harness.readAddress(string.concat(addressConfig(), '\nL2_GAS_ORACLE_SENDER_PRIVATE_KEY = "unused"\n')),
            KMS_SENDER
        );
    }

    function testRejectsMissingAddress() public {
        vm.expectRevert();
        harness.readAddress("[accounts]\n");
    }

    function testRejectsMalformedAddress() public {
        vm.expectRevert();
        harness.readAddress('[accounts]\nL2_GAS_ORACLE_SENDER_ADDR = "invalid"\n');
    }

    function testRejectsZeroAddress() public {
        vm.expectRevert("L2_GAS_ORACLE_SENDER_ADDR must not be zero");
        harness.readAddress('[accounts]\nL2_GAS_ORACLE_SENDER_ADDR = "0x0000000000000000000000000000000000000000"\n');
    }

    function addressConfig() private pure returns (string memory) {
        return '[accounts]\nL2_GAS_ORACLE_SENDER_ADDR = "0xbEEC0A88c46ad59AA82aA0208F914a1ba6b83e5c"\n';
    }
}
