#!/usr/bin/env python3
"""Exercise gen-configs and deploy.sh against an ephemeral Anvil with 10 DOGE.

Requires Python 3.11+, Foundry, jq and installed repository dependencies.
Anvil does not implement DogeOS's overhead algorithm; this checks transaction
ordering, wiring, balances and omitted deployments, not native fee activation.
"""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import tomllib
import urllib.request


# Public test key, never used outside the local Anvil instance.
TEST_KEY = "0x" + "0" * 63 + "1"
DEPLOYER = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
OWNER = "0x1111111111111111111111111111111111111111"
GAS_PRICE = 840_000_000_000
NATIVE_DOGE = "0x530000000000000000000000000000000000d09e"
OMITTED = re.compile(
    r"L[12]_(GATEWAY_ROUTER|ETH_GATEWAY|WETH_GATEWAY|WDOGE_GATEWAY|"
    r"STANDARD_ERC20_GATEWAY|CUSTOM_ERC20_GATEWAY|ERC721_GATEWAY|"
    r"ERC1155_GATEWAY|SCROLL_STANDARD_ERC20)"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy", choices=["true", "false"], default="false")
    legacy = parser.parse_args().legacy == "true"
    root = Path(__file__).resolve().parents[2]
    stage = Path(tempfile.mkdtemp(prefix="dogeos-bootstrap-"))
    print(f"Bootstrap test artifacts: {stage}", flush=True)
    for name in ["src", "scripts", "docker", "lib", "node_modules", "foundry.toml", "remappings.txt"]:
        (stage / name).symlink_to(root / name)
    for name in ["artifacts", "cache"]:
        (root / name).mkdir(exist_ok=True)
        (stage / name).symlink_to(root / name, target_is_directory=True)
    (stage / "volume").mkdir()
    config = (root / "docker/templates/config.toml").read_text()
    for key, value in {
        "DEPLOYER_PRIVATE_KEY": TEST_KEY,
        "DEPLOYER_ADDR": DEPLOYER,
        "OWNER_ADDR": OWNER,
        "L2_GAS_ORACLE_SENDER_ADDR": "0x3333333333333333333333333333333333333333",
    }.items():
        config = config.replace(f'{key} = ""', f'{key} = "{value}"')
    config = config.replace(
        'FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x0000000000000000000000000000000000000000"',
        'FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x2222222222222222222222222222222222222222"',
    )
    (stage / "volume/config.toml").write_text(config)
    # A regenerated manifest must not advertise an older gateway deployment.
    (stage / "volume/config-contracts.toml").write_text(
        'L2_ETH_GATEWAY_PROXY_ADDR = "0x4444444444444444444444444444444444444444"\n'
    )
    env = dict(os.environ, DEPLOYER_PRIVATE_KEY=TEST_KEY, FOUNDRY_JOBS="2", RAYON_NUM_THREADS="2")

    def run(command, log):
        with (stage / log).open("w") as output:
            result = subprocess.run(command, cwd=stage, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=300)
        if result.returncode:
            raise RuntimeError(f"{log}:\n{(stage / log).read_text()[-5000:]}")

    run(["bash", "docker/scripts/gen-configs.sh"], "generate.log")
    addresses = tomllib.loads((stage / "volume/config-contracts.toml").read_text())
    # NativeDogeToken is a genesis predeploy, not a deploy.sh manifest entry.
    addresses["L2_NATIVE_DOGE_TOKEN_ADDR"] = NATIVE_DOGE
    assert all(not value for name, value in addresses.items() if OMITTED.match(name))
    frontend = (stage / "volume/frontend-config.yaml").read_text()
    assert not re.search(r'REACT_APP_L[12]_(?:GATEWAY_ROUTER|\w+_GATEWAY)_PROXY_ADDR = "0x', frontend)
    wrapped = (stage / "volume/genesis.yaml").read_text().splitlines()
    genesis = json.loads("\n".join(line[2:] for line in wrapped[1:]))
    (stage / "genesis.json").write_text(json.dumps(genesis))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"

    def rpc(method, params):
        request = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1,
            "method": method, "params": params}).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    def call(name, signature):
        data = subprocess.check_output(["cast", "calldata", signature], text=True).strip()
        return rpc("eth_call", [{"to": addresses[name], "data": data}, "latest"])

    def address_call(name, signature):
        return "0x" + call(name, signature)[-40:].lower()

    with (stage / "anvil.log").open("w") as log:
        node = subprocess.Popen(["anvil", "--host", "127.0.0.1", "--port", str(port),
            "--init", str(stage / "genesis.json"), "--hardfork", "cancun", "--accounts", "0",
            "--gas-limit", "30000000", "--base-fee", "420000000000", "--block-time", "1"],
            stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                try:
                    rpc("eth_chainId", [])
                    break
                except Exception:
                    if node.poll() is not None:
                        raise RuntimeError((stage / "anvil.log").read_text())
                    time.sleep(0.1)
            else:
                raise RuntimeError("Anvil did not start")
            # Audited token contracts and the queue carrying AppendOnlyMerkleTree
            # must already exist in genesis, independently of deploy.sh.
            for name in ["L2_NATIVE_DOGE_TOKEN_ADDR", "L2_WDOGE_ADDR", "L2_MESSAGE_QUEUE_ADDR"]:
                address = addresses[name]
                code = genesis["alloc"][address.lower()]["code"]
                assert code != "0x" and len(code) > 2, name
                assert rpc("eth_getCode", [address, "latest"]) == code, name
            supply = int(tomllib.loads(config)["genesis"]["L2_MAX_NATIVE_DOGE_SUPPLY"])
            assert int(call("L2_NATIVE_DOGE_TOKEN_ADDR", "totalSupply()"), 16) == supply
            assert int(call("L2_WDOGE_ADDR", "decimals()"), 16) == 18
            before = int(rpc("eth_getBalance", [DEPLOYER, "latest"]), 16)
            assert before == 10 * 10**18
            max_fee = GAS_PRICE if legacy else 840_000_000_000
            env.update(L1_RPC_ENDPOINT=url, L2_RPC_ENDPOINT=url, ETH_GAS_PRICE=str(max_fee),
                       DEPLOY_LEGACY="true" if legacy else "false", ETH_PRIORITY_GAS_PRICE="1000000000")
            run(["bash", "docker/scripts/deploy.sh"], "deploy.log")
            assert 'BATCH_SIZE: 100' in (stage / "deploy.log").read_text()
            blocks = [rpc("eth_getBlockByNumber", [hex(i), True])
                      for i in range(1, int(rpc("eth_blockNumber", []), 16) + 1)]
            transactions = sorted([tx for block in blocks for tx in block["transactions"]],
                                  key=lambda tx: int(tx["nonce"], 16))
            receipts = [rpc("eth_getTransactionReceipt", [tx["hash"]]) for tx in transactions]
            assert transactions and all(int(r["status"], 16) == 1 for r in receipts)
            factory = "0x4e59b44847b379578588920ca78fbf26c0b4956c"
            assert sum(tx["to"].lower() == factory for tx in transactions) == 9
            overhead_selector = subprocess.check_output(
                ["cast", "sig", "updateBaseFeeOverhead(uint256)"], text=True).strip()
            ownership_selector = subprocess.check_output(
                ["cast", "sig", "transferOwnership(address)"], text=True).strip()
            updates = [i for i, tx in enumerate(transactions) if tx["input"].startswith(overhead_selector)]
            assert len(updates) == 1
            update = updates[0]
            assert transactions[update]["to"].lower() == addresses["L2_SYSTEM_CONFIG_PROXY_ADDR"].lower()
            assert int(transactions[update]["input"][10:], 16) == 420_000_000_000
            assert not any(tx["input"].startswith(ownership_selector) for tx in transactions[:update])
            assert len(transactions[update + 1:]) == 8
            assert all(tx["input"].startswith(ownership_selector) for tx in transactions[update + 1:])
            for name in ["L1_GAS_PRICE_ORACLE_ADDR", "L2_MESSAGE_QUEUE_ADDR", "L2_WHITELIST_ADDR",
                         "L2_TX_FEE_VAULT_ADDR", "L2_PROXY_ADMIN_ADDR", "L2_DOGEOS_MESSENGER_PROXY_ADDR",
                         "L2_MOAT_PROXY_ADDR", "L2_SYSTEM_CONFIG_PROXY_ADDR"]:
                assert address_call(name, "owner()") == OWNER.lower(), name
            for name, signature, target in [
                ("L2_MOAT_PROXY_ADDR", "messenger()", "L2_DOGEOS_MESSENGER_PROXY_ADDR"),
                ("L2_DOGEOS_MESSENGER_PROXY_ADDR", "MOAT()", "L2_MOAT_PROXY_ADDR"),
                ("L2_MESSAGE_QUEUE_ADDR", "messenger()", "L2_DOGEOS_MESSENGER_PROXY_ADDR"),
                ("L2_TX_FEE_VAULT_ADDR", "messenger()", "L2_FEE_VAULT_MOAT_ADAPTER_ADDR"),
                ("L2_FEE_VAULT_MOAT_ADAPTER_ADDR", "MOAT()", "L2_MOAT_PROXY_ADDR"),
            ]:
                assert address_call(name, signature) == addresses[target].lower(), (name, signature)
            assert int(call("L2_SYSTEM_CONFIG_PROXY_ADDR", "baseFeeOverhead()"), 16) == 420_000_000_000
            # Fail on missing/empty audited deployment entries, not just empty
            # bytecode at the optional addresses below. DogeAddressLib and
            # WithdrawalEnvelope are internal libraries compiled into Moat and
            # the messenger; AppendOnlyMerkleTree is inherited by the queue.
            for name in ["L2_MOAT_IMPLEMENTATION_ADDR", "L2_MOAT_PROXY_ADDR",
                         "L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR", "L2_DOGEOS_MESSENGER_PROXY_ADDR",
                         "L2_FEE_VAULT_MOAT_ADAPTER_ADDR", "L2_WDOGE_ADDR", "L2_MESSAGE_QUEUE_ADDR",
                         "L2_NATIVE_DOGE_TOKEN_ADDR"]:
                assert addresses.get(name), f"Missing audited deployment: {name}"
                assert rpc("eth_getCode", [addresses[name], "latest"]) != "0x", name
            for name, value in addresses.items():
                if value and (name.startswith("L2_") or name == "L1_GAS_PRICE_ORACLE_ADDR"):
                    assert rpc("eth_getCode", [value, "latest"]) != "0x", name
            after = int(rpc("eth_getBalance", [DEPLOYER, "latest"]), 16)
            gas = sum(int(r["gasUsed"], 16) for r in receipts)
            assert all(int(tx["type"], 16) == (0 if legacy else 2) for tx in transactions)
            base_fees = {block["hash"]: int(block["baseFeePerGas"], 16) for block in blocks}
            for tx, receipt in zip(transactions, receipts):
                if not legacy:
                    assert int(tx["maxFeePerGas"], 16) == max_fee
                    assert int(tx["maxPriorityFeePerGas"], 16) == 1_000_000_000
                expected = GAS_PRICE if legacy else min(max_fee, base_fees[receipt["blockHash"]] + 1_000_000_000)
                assert int(receipt["effectiveGasPrice"], 16) == expected
            assert before - after == sum(int(r["gasUsed"], 16) * int(r["effectiveGasPrice"], 16) for r in receipts)
            summary = {"legacy": legacy, "transactions": len(transactions), "new_contracts": 9, "gas_used": gas,
                       "fee_wei": before - after, "remaining_wei": after,
                       "overhead_transaction": update + 1, "ownership_transactions_after": 8}
            (stage / "summary.json").write_text(json.dumps(summary, indent=2))
            (stage / "transactions.json").write_text(json.dumps(transactions, indent=2))
            print(json.dumps(summary, indent=2), flush=True)
        finally:
            node.terminate()
            try:
                node.wait(timeout=10)
            except subprocess.TimeoutExpired:
                node.kill()
                node.wait()


if __name__ == "__main__":
    main()
