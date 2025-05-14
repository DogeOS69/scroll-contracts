// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// import {WrappedEther} from "../../src/L2/predeploys/WrappedEther.sol";
import {WrappedDoge} from "../../src/dogeos/WrappedDoge.sol";

contract DeployWeth is Script {
    // address L1_WETH_ADDR = vm.envAddress("L1_WETH_ADDR");
    // address L2_WETH_ADDR = vm.envAddress("L2_WETH_ADDR");
    address L1_WDOGE_ADDR = vm.envAddress("L1_WDOGE_ADDR");
    address L2_WDOGE_ADDR = vm.envAddress("L2_WDOGE_ADDR");

    function run() external {
        // deploy weth only if we're running a private L1 network
        if (L1_WDOGE_ADDR == address(0)) {
            uint256 L1_WDOGE_DEPLOYER_PRIVATE_KEY = vm.envUint("L1_WDOGE_DEPLOYER_PRIVATE_KEY");
            vm.startBroadcast(L1_WDOGE_DEPLOYER_PRIVATE_KEY);
            // WrappedEther weth = new WrappedEther();
            WrappedDoge wdoge = new WrappedDoge();
            L1_WDOGE_ADDR = address(wdoge);
            vm.stopBroadcast();
        }

        logAddress("L1_WDOGE_ADDR", L1_WDOGE_ADDR);
        logAddress("L2_WDOGE_ADDR", L2_WDOGE_ADDR);
    }

    function logAddress(string memory name, address addr) internal view {
        console.log(string(abi.encodePacked(name, "=", vm.toString(address(addr)))));
    }
}
