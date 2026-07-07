// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {FeeVaultMoatAdapter} from "../../src/dogeos/FeeVaultMoatAdapter.sol";
import {IMoat} from "../../src/dogeos/IMoat.sol";
import {L2TxFeeVault} from "../../src/L2/predeploys/L2TxFeeVault.sol";

import {CONFIG_PATH, CONFIG_CONTRACTS_PATH} from "./Constants.sol";

/// @notice Broadcasts the owner calls that route L2TxFeeVault withdrawals through the Moat.
contract SubmitFeeVaultRewire is Script {
    using stdToml for string;

    struct Inputs {
        address feeVault;
        address moat;
        address adapter;
        address dogeRecipient;
    }

    function run() external {
        Inputs memory inputs = _readInputs();
        uint256 ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");
        address signer = vm.addr(ownerPrivateKey);

        L2TxFeeVault vault = L2TxFeeVault(payable(inputs.feeVault));
        IMoat moat = IMoat(inputs.moat);
        FeeVaultMoatAdapter adapter = FeeVaultMoatAdapter(inputs.adapter);

        _preflight(inputs, vault, moat, adapter, signer);

        uint256 satoshi = moat.SATOSHI_TO_WEI();
        uint256 moatMin = moat.minWithdrawalAmount();
        uint256 requiredMin = moatMin + satoshi;

        vm.startBroadcast(ownerPrivateKey);

        console.log("");
        console.log("step 1/4: Moat.setFeeExempt(adapter, true)");
        if (moat.feeExemptCallers(inputs.adapter)) {
            console.log("already exempt - skipping");
        } else {
            moat.setFeeExempt(inputs.adapter, true);
        }

        console.log("");
        console.log("step 2/4: L2TxFeeVault.updateRecipient(dogeRecipient)");
        if (vault.recipient() == inputs.dogeRecipient) {
            console.log("already set - skipping");
        } else {
            vault.updateRecipient(inputs.dogeRecipient);
        }

        console.log("");
        console.log("step 3/4: L2TxFeeVault.updateMinWithdrawAmount(requiredMin)");
        if (vault.minWithdrawAmount() >= requiredMin) {
            console.log("already >= required - skipping");
        } else {
            vault.updateMinWithdrawAmount(requiredMin);
        }

        console.log("");
        console.log("step 4/4: L2TxFeeVault.updateMessenger(adapter)");
        if (vault.messenger() == inputs.adapter) {
            console.log("already set - skipping");
        } else {
            vault.updateMessenger(inputs.adapter);
        }

        vm.stopBroadcast();
    }

    function _readInputs() private view returns (Inputs memory inputs) {
        string memory cfg = vm.readFile(CONFIG_PATH);
        string memory contractsCfg = vm.readFile(CONFIG_CONTRACTS_PATH);

        inputs.feeVault = contractsCfg.readAddress(".L2_TX_FEE_VAULT_ADDR");
        inputs.moat = contractsCfg.readAddress(".L2_MOAT_PROXY_ADDR");
        inputs.adapter = contractsCfg.readAddress(".L2_FEE_VAULT_MOAT_ADAPTER_ADDR");
        inputs.dogeRecipient = cfg.readAddress(".contracts.FEE_VAULT_DOGE_RECIPIENT_ADDR");

        require(inputs.feeVault != address(0), "L2_TX_FEE_VAULT_ADDR is zero");
        require(inputs.moat != address(0), "L2_MOAT_PROXY_ADDR is zero");
        require(inputs.adapter != address(0), "L2_FEE_VAULT_MOAT_ADAPTER_ADDR is zero");
        require(inputs.dogeRecipient != address(0), "FEE_VAULT_DOGE_RECIPIENT_ADDR is zero");
    }

    function _preflight(
        Inputs memory inputs,
        L2TxFeeVault vault,
        IMoat moat,
        FeeVaultMoatAdapter adapter,
        address signer
    ) private view {
        require(inputs.feeVault.code.length != 0, "L2_TX_FEE_VAULT_ADDR has no code");
        require(inputs.moat.code.length != 0, "L2_MOAT_PROXY_ADDR has no code");
        require(inputs.adapter.code.length != 0, "L2_FEE_VAULT_MOAT_ADAPTER_ADDR has no code");

        require(adapter.FEE_VAULT() == inputs.feeVault, "adapter FEE_VAULT mismatch");
        require(adapter.MOAT() == inputs.moat, "adapter MOAT mismatch");

        address moatOwner = moat.owner();
        address vaultOwner = vault.owner();
        require(signer == moatOwner, "OWNER_PRIVATE_KEY does not control Moat owner");
        require(signer == vaultOwner, "OWNER_PRIVATE_KEY does not control fee vault owner");

        uint256 satoshi = moat.SATOSHI_TO_WEI();
        uint256 moatMin = moat.minWithdrawalAmount();

        console.log("");
        console.log("forge script rewire preflight");
        console.log("signer:              ", signer);
        console.log("moat owner:          ", moatOwner);
        console.log("vault owner:         ", vaultOwner);
        console.log("adapter fee-exempt:  ", moat.feeExemptCallers(inputs.adapter));
        console.log("vault recipient:     ", vault.recipient());
        console.log("target recipient:    ", inputs.dogeRecipient);
        console.log("vault minWithdraw:   ", vault.minWithdrawAmount());
        console.log("required vault min:  ", moatMin + satoshi);
        console.log("vault messenger:     ", vault.messenger());
        console.log("target messenger:    ", inputs.adapter);
    }
}
