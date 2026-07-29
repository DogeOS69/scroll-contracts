// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L2TxFeeVault} from "../../src/L2/predeploys/L2TxFeeVault.sol";

import {CONFIG_CONTRACTS_PATH} from "./Constants.sol";

abstract contract ProxyUpgradeScriptBase is Script {
    using stdToml for string;

    struct UpgradeInputs {
        address proxyAdmin;
        address proxy;
        address implementation;
    }

    function _runUpgrade(string memory label, UpgradeInputs memory inputs) internal {
        _validateUpgradeInputs(inputs);

        uint256 ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");
        address signer = vm.addr(ownerPrivateKey);

        ProxyAdmin proxyAdmin = ProxyAdmin(inputs.proxyAdmin);
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(inputs.proxy);

        address owner = proxyAdmin.owner();
        require(signer == owner, "OWNER_PRIVATE_KEY does not control ProxyAdmin owner");

        address currentImpl = proxyAdmin.getProxyImplementation(proxy);

        console.log("");
        console.log("forge script proxy upgrade preflight");
        console.log("target:        ", label);
        console.log("signer:        ", signer);
        console.log("ProxyAdmin:    ", inputs.proxyAdmin);
        console.log("ProxyAdmin owner:", owner);
        console.log("proxy:         ", inputs.proxy);
        console.log("impl before:   ", currentImpl);
        console.log("target impl:   ", inputs.implementation);

        if (currentImpl == inputs.implementation) {
            console.log("target implementation is already active - skipping");
            return;
        }

        vm.startBroadcast(ownerPrivateKey);
        proxyAdmin.upgrade(proxy, inputs.implementation);
        vm.stopBroadcast();
    }

    function _validateUpgradeInputs(UpgradeInputs memory inputs) private view {
        require(inputs.proxyAdmin != address(0), "L2_PROXY_ADMIN_ADDR is zero");
        require(inputs.proxy != address(0), "proxy address is zero");
        require(inputs.implementation != address(0), "implementation address is zero");
        require(inputs.proxyAdmin.code.length != 0, "L2_PROXY_ADMIN_ADDR has no code");
        require(inputs.proxy.code.length != 0, "proxy has no code");
        require(inputs.implementation.code.length != 0, "implementation has no code");
    }

    function _contractsCfg() internal view returns (string memory) {
        return vm.readFile(CONFIG_CONTRACTS_PATH);
    }
}

contract SubmitMoatProxyUpgrade is ProxyUpgradeScriptBase {
    using stdToml for string;

    function run() external {
        string memory contractsCfg = _contractsCfg();

        _runUpgrade(
            "Moat proxy",
            UpgradeInputs({
                proxyAdmin: contractsCfg.readAddress(".L2_PROXY_ADMIN_ADDR"),
                proxy: contractsCfg.readAddress(".L2_MOAT_PROXY_ADDR"),
                implementation: contractsCfg.readAddress(".L2_MOAT_IMPLEMENTATION_ADDR")
            })
        );
    }
}

contract SubmitDogeOsMessengerProxyUpgrade is ProxyUpgradeScriptBase {
    using stdToml for string;

    function run() external {
        string memory contractsCfg = _contractsCfg();

        address feeVault = contractsCfg.readAddress(".L2_TX_FEE_VAULT_ADDR");
        address adapter = contractsCfg.readAddress(".L2_FEE_VAULT_MOAT_ADAPTER_ADDR");
        _requireFeeVaultRewired(feeVault, adapter);

        _runUpgrade(
            "L2DogeOsMessenger proxy",
            UpgradeInputs({
                proxyAdmin: contractsCfg.readAddress(".L2_PROXY_ADMIN_ADDR"),
                proxy: contractsCfg.readAddress(".L2_DOGEOS_MESSENGER_PROXY_ADDR"),
                implementation: contractsCfg.readAddress(".L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR")
            })
        );
    }

    function _requireFeeVaultRewired(address feeVault, address adapter) private view {
        require(feeVault != address(0), "L2_TX_FEE_VAULT_ADDR is zero");
        require(adapter != address(0), "L2_FEE_VAULT_MOAT_ADAPTER_ADDR is zero");
        require(feeVault.code.length != 0, "L2_TX_FEE_VAULT_ADDR has no code");
        require(adapter.code.length != 0, "L2_FEE_VAULT_MOAT_ADAPTER_ADDR has no code");

        address messenger = L2TxFeeVault(payable(feeVault)).messenger();
        require(messenger == adapter, "fee vault is not rewired through adapter");
    }
}
