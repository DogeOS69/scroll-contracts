// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L2TxFeeVault} from "../../src/L2/predeploys/L2TxFeeVault.sol";
import {IMoat} from "../../src/dogeos/IMoat.sol";
import {LegacyReplayCheck} from "./LegacyReplayCheck.sol";

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

    function _validateUpgradeInputs(UpgradeInputs memory inputs) internal view {
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

        UpgradeInputs memory inputs = UpgradeInputs({
            proxyAdmin: contractsCfg.readAddress(".L2_PROXY_ADMIN_ADDR"),
            proxy: contractsCfg.readAddress(".L2_MOAT_PROXY_ADDR"),
            implementation: contractsCfg.readAddress(".L2_MOAT_IMPLEMENTATION_ADDR")
        });
        _validateUpgradeInputs(inputs);
        _requireMessengerBinding(
            inputs.proxy,
            inputs.implementation,
            contractsCfg.readAddress(".L2_DOGEOS_MESSENGER_PROXY_ADDR")
        );

        _runUpgrade("Moat proxy", inputs);
    }

    /// @dev The new implementation binds the messenger immutably (Moat.MESSENGER). It must be
    ///      the messenger the live proxy already uses and the configured messenger proxy, or
    ///      every deposit and withdrawal would break after the upgrade. Not bypassable.
    function _requireMessengerBinding(
        address proxy,
        address implementation,
        address configuredMessenger
    ) private view {
        require(configuredMessenger != address(0), "L2_DOGEOS_MESSENGER_PROXY_ADDR is zero");

        address currentMessenger = IMoat(proxy).messenger();
        address boundMessenger = IMoat(implementation).MESSENGER();
        console.log("current messenger:", currentMessenger);
        console.log("new impl MESSENGER:", boundMessenger);

        require(currentMessenger != address(0), "Moat proxy messenger() is zero");
        require(boundMessenger == currentMessenger, "new implementation MESSENGER != proxy's current messenger()");
        require(
            boundMessenger == configuredMessenger,
            "new implementation MESSENGER != L2_DOGEOS_MESSENGER_PROXY_ADDR"
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

        UpgradeInputs memory inputs = UpgradeInputs({
            proxyAdmin: contractsCfg.readAddress(".L2_PROXY_ADMIN_ADDR"),
            proxy: contractsCfg.readAddress(".L2_DOGEOS_MESSENGER_PROXY_ADDR"),
            implementation: contractsCfg.readAddress(".L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR")
        });
        _validateUpgradeInputs(inputs);

        // Replay protection must survive the upgrade: a messenger that relayed deposits under the
        // per-hash mapping must keep checking it, and a rollback to a pre-bitmap implementation
        // would drop protection for deposits relayed since (ALLOW_MESSENGER_ROLLBACK=1 overrides
        // only the latter). The messenger's Initializable flag is the low byte of slot 0.
        bool initialized = uint8(uint256(vm.load(inputs.proxy, bytes32(0)))) != 0;
        LegacyReplayCheck.requireSafeUpgrade(
            inputs.proxy,
            initialized,
            inputs.implementation,
            vm.envOr("ALLOW_MESSENGER_ROLLBACK", uint256(0)) == 1
        );

        _runUpgrade("L2DogeOsMessenger proxy", inputs);
    }

    function _requireFeeVaultRewired(address feeVault, address adapter) private view {
        require(feeVault != address(0), "L2_TX_FEE_VAULT_ADDR is zero");
        require(adapter != address(0), "L2_FEE_VAULT_MOAT_ADAPTER_ADDR is zero");
        require(feeVault.code.length != 0, "L2_TX_FEE_VAULT_ADDR has no code");
        require(adapter.code.length != 0, "L2_FEE_VAULT_MOAT_ADAPTER_ADDR has no code");

        address messenger = L2TxFeeVault(payable(feeVault)).messenger();
        if (messenger != adapter) {
            require(vm.envOr("FORCE", uint256(0)) == uint256(1), "fee vault is not rewired through adapter");
            console.log("FORCE=1 set - fee vault rewire guard bypassed");
        }
    }
}
