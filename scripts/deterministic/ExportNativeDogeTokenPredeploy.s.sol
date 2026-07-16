// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {NativeDogeToken} from "../../src/dogeos/NativeDogeToken.sol";
import {DogeOSPredeploy} from "../../src/libraries/constants/DogeOSPredeploy.sol";

import {CONFIG_PATH, NATIVE_DOGE_TOKEN_PREDEPLOY_JSON_PATH} from "./Constants.sol";
import {NativeDogeSupplyConfig} from "./NativeDogeSupplyConfig.sol";

/// @notice Exports the hardfork payload for the NativeDogeToken predeploy.
/// @dev The runtime bytecode is derived from the same constructor path used by
///      GenerateGenesis. Hardfork callers must install this runtime code at
///      L2_NATIVE_DOGE_TOKEN and initialize slot 0 to totalSupplySlotValue.
contract ExportNativeDogeTokenPredeploy is NativeDogeSupplyConfig {
    function run() external {
        string memory cfg = vm.readFile(CONFIG_PATH);
        _write(readL2MaxNativeDogeSupply(cfg));
    }

    function run(uint256 totalSupply_) external {
        _write(totalSupply_);
    }

    function _write(uint256 totalSupply_) private {
        NativeDogeToken token = new NativeDogeToken(totalSupply_);
        bytes memory runtimeBytecode = address(token).code;
        bytes32 totalSupplySlot = bytes32(uint256(0));
        bytes32 totalSupplySlotValue = vm.load(address(token), totalSupplySlot);

        string memory root = "nativeDogeTokenPredeploy";
        vm.serializeString(root, "contractName", "NativeDogeToken");
        vm.serializeAddress(root, "address", DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        vm.serializeAddress(root, "nativeTransferPrecompile", DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE);
        vm.serializeString(root, "totalSupply", vm.toString(totalSupply_));
        vm.serializeBytes32(root, "totalSupplySlot", totalSupplySlot);
        vm.serializeBytes32(root, "totalSupplySlotValue", totalSupplySlotValue);
        vm.serializeBytes32(root, "runtimeBytecodeHash", keccak256(runtimeBytecode));
        string memory json = vm.serializeBytes(root, "runtimeBytecode", runtimeBytecode);

        vm.createDir("./volume", true);
        vm.writeJson(json, NATIVE_DOGE_TOKEN_PREDEPLOY_JSON_PATH);
    }
}
