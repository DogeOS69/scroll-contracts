// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

abstract contract NativeDogeSupplyConfig is Script {
    using stdToml for string;

    function readL2MaxNativeDogeSupply(string memory configToml) internal view returns (uint256) {
        bool hasNativeKey = vm.keyExistsToml(configToml, ".genesis.L2_MAX_NATIVE_DOGE_SUPPLY");
        bool hasLegacyEthKey = vm.keyExistsToml(configToml, ".genesis.L2_MAX_ETH_SUPPLY");

        if (!hasNativeKey && !hasLegacyEthKey) {
            revert("missing genesis L2_MAX_NATIVE_DOGE_SUPPLY");
        }

        uint256 nativeDogeSupply = hasNativeKey
            ? configToml.readUint(".genesis.L2_MAX_NATIVE_DOGE_SUPPLY")
            : configToml.readUint(".genesis.L2_MAX_ETH_SUPPLY");

        if (hasNativeKey && hasLegacyEthKey) {
            uint256 legacyEthSupply = configToml.readUint(".genesis.L2_MAX_ETH_SUPPLY");
            if (nativeDogeSupply != legacyEthSupply) {
                revert("L2_MAX_NATIVE_DOGE_SUPPLY must match L2_MAX_ETH_SUPPLY");
            }
        }

        return nativeDogeSupply;
    }
}
