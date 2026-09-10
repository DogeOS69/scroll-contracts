#!/usr/bin/env python3
"""Compare shared TOML templates using local contract deployment and CLI commands.

Requires Python 3.11+, forge, anvil, cast, jq, Node.js, installed repository
node_modules/lib dependencies, and a built sibling scroll-sdk-cli.
Only ephemeral Anvil receives transactions. Verification requests are mocked.
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import tomllib
import urllib.request
from pathlib import Path

TEST_KEY = "0x" + "0" * 63 + "1"


def deploy_locally(stage, label):
    output = stage / "evidence" / label
    output.mkdir(exist_ok=True)
    for name in [
        "config.toml",
        "config-contracts.toml",
        "genesis.yaml",
        "frontend-config.yaml",
    ]:
        (output / name).write_bytes((stage / "volume" / name).read_bytes())
    text = (output / "genesis.yaml").read_text()
    genesis = json.loads("\n".join(line[2:] for line in text.splitlines()[1:]))
    (output / "genesis.json").write_text(json.dumps(genesis))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    log = (output / "anvil.log").open("w")
    node = subprocess.Popen(
        [
            "anvil",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--init",
            str(output / "genesis.json"),
            "--hardfork",
            "cancun",
            "--gas-limit",
            "100000000",
            "--silent",
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )

    def rpc(method, params=[]):
        req = urllib.request.Request(
            url,
            data=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
            ).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        if "error" in data:
            raise RuntimeError(data["error"])
        return data["result"]

    try:
        for i in range(100):
            if node.poll() is not None:
                raise RuntimeError((output / "anvil.log").read_text())
            try:
                rpc("eth_chainId")
                break
            except Exception:
                time.sleep(0.1)
        else:
            raise RuntimeError("Anvil did not start")
        env = {
            **os.environ,
            "DEPLOYER_PRIVATE_KEY": TEST_KEY,
            "L2_RPC_ENDPOINT": url,
            "L1_RPC_ENDPOINT": url,
            "FOUNDRY_JOBS": "2",
            "RAYON_NUM_THREADS": "2",
        }
        with (output / "deploy.log").open("w") as f:
            result = subprocess.run(
                ["bash", "docker/scripts/deploy.sh"],
                cwd=stage,
                env=env,
                stdout=f,
                stderr=subprocess.STDOUT,
                timeout=240,
            )
        if result.returncode:
            raise RuntimeError((output / "deploy.log").read_text()[-9000:])
        addresses = tomllib.loads((output / "config-contracts.toml").read_text())
        code = {
            k: rpc("eth_getCode", [v, "latest"])
            for k, v in addresses.items()
            if len(v) == 42 and (k.startswith("L2_") or k == "L1_GAS_PRICE_ORACLE_ADDR")
        }
        code["L2_NATIVE_DOGE_TOKEN_ADDR"] = rpc(
            "eth_getCode", ["0x530000000000000000000000000000000000d09e", "latest"]
        )
        assert all(v != "0x" for v in code.values()), [
            k for k, v in code.items() if v == "0x"
        ]
        state = {}

        def call(name, sig, *args):
            result = subprocess.run(
                ["cast", "call", "--rpc-url", url, addresses[name], sig, *args],
                text=True,
                capture_output=True,
                check=True,
            )
            state[name + "." + sig + " " + ",".join(args)] = result.stdout.strip()

        for name in [
            "L2_MOAT_PROXY_ADDR",
            "L2_TX_FEE_VAULT_ADDR",
            "L1_GAS_PRICE_ORACLE_ADDR",
            "L2_WHITELIST_ADDR",
            "L2_PROXY_ADMIN_ADDR",
        ]:
            call(name, "owner()(address)")
        call("L2_TX_FEE_VAULT_ADDR", "recipient()(address)")
        call("L2_TX_FEE_VAULT_ADDR", "messenger()(address)")
        call("L2_MOAT_PROXY_ADDR", "feeRecipient()(address)")
        call("L2_MOAT_PROXY_ADDR", "withdrawalFee()(uint256)")
        call("L2_MOAT_PROXY_ADDR", "depositFee()(uint256)")
        call("L2_MOAT_PROXY_ADDR", "minWithdrawalAmount()(uint256)")
        call(
            "L2_WHITELIST_ADDR",
            "isSenderAllowed(address)(bool)",
            "0x3333333333333333333333333333333333333333",
        )
        for key in ["commitScalar", "blobScalar", "scalar", "penaltyFactor"]:
            call("L1_GAS_PRICE_ORACLE_ADDR", key + "()(uint256)")
        (output / "onchain.json").write_text(
            json.dumps({"code": code, "state": state}, indent=2)
        )
        print(
            json.dumps(
                {
                    "label": label,
                    "deployed_contracts_checked": len(code),
                    "state_checks": len(state),
                    "block": rpc("eth_blockNumber"),
                }
            ),
            flush=True,
        )
    finally:
        node.terminate()
        try:
            node.wait(timeout=10)
        except subprocess.TimeoutExpired:
            node.kill()
            node.wait()
        log.close()


def run_cli(stage, cli, label):
    root = stage / "evidence" / ("cli-" + label)
    root.mkdir(exist_ok=True)
    (root / ".data").mkdir(exist_ok=True)
    (root / "values").mkdir(exist_ok=True)
    config = (stage / "evidence" / label / "config.toml").read_text()
    # Non-secret fixture values let us compare generated database/node secrets.
    for key in [
        "BLOCKSCOUT_DB_CONNECTION_STRING",
    ]:
        config = config.replace(
            key + ' = ""',
            key + ' = "postgres://fixture:fixture@localhost/' + key.lower() + '"',
        )
    config = (
        config.replace(
            "L2GETH_KEYSTORE = ''", """L2GETH_KEYSTORE = '{"fixture":true}' """
        )
        .replace('L2GETH_PASSWORD = ""', 'L2GETH_PASSWORD = "fixture"')
        .replace('L2GETH_NODEKEY = ""', 'L2GETH_NODEKEY = "' + "1" * 64 + '"')
        .replace('L2GETH_NODEKEY=""', 'L2GETH_NODEKEY="' + "2" * 64 + '"')
    )
    config = config.replace(
        "[accounts]",
        '[accounts]\nL2_TESTNET_ACTIVITY_HELPER_PRIVATE_KEY = "' + TEST_KEY + '"',
    )
    (root / "config.toml").write_text(config)
    shutil.copy2(
        stage / "evidence" / label / "config-contracts.toml",
        root / "config-contracts.toml",
    )
    key = "0x" + "0" * 63 + "1"
    (root / ".data/doge-config.toml").write_text(
        '''network = "testnet"
    [wallet]
    path = ".data/wallet.json"
    [dogecoinClusterRpc]
    url = "http://dogecoin:18332"
    username = "fixture"
    password = "fixture"
    [dogecoinExternalRpc]
    url = "http://127.0.0.1:18332"
    username = "fixture"
    password = "fixture"
    [defaults]
    dogecoinIndexerStartHeight = "0"
    l1GenesisBlock = "1"
    [ethereumDa]
    chain = "sepolia"
    beaconRpcUrl = "http://beacon:5052"
    minFinality = "finalized"
    chainId = 11155111
    submitterRpcUrl = "http://anvil:8545"
    [signers.l1CommitSender]
    backend = "local"
    [signers.l2GasOracleSender]
    backend = "local"
    [accounts]
    L1_COMMIT_SENDER_PRIVATE_KEY = "'''
        + key
        + '''"
    L1_COMMIT_SENDER_ADDR = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    L2_GAS_ORACLE_SENDER_PRIVATE_KEY = "'''
        + key
        + """"
    L2_GAS_ORACLE_SENDER_ADDR = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    """
    )
    (root / ".data/output-withdrawal-processor.toml").write_text(
        """bridge_address = "fixture"
    fee_signer_key = "fixture-fee"
    sequencer_signer_key = "fixture-sequencer"
    genesis_sequencer_txid = "f5eedbcaed2b12685bfc046c04ae7827e47ba6b75cb09342a5ec062ee4c4997f"
    genesis_sequencer_vout = 0
    genesis_sequencer_tx_hex = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff0101000000000000000000000000"
    network_str = "testnet"
    """
    )
    (root / ".data/bridge.json").write_text(json.dumps({"redeem_script_hex": "51"}))
    (root / ".data/output-test-data.json").write_text(
        json.dumps(
            {
                "fee_wallet_address": "fixture-fee",
                "sequencer_address": "fixture-sequencer",
            }
        )
    )
    (root / "Makefile").write_text(
        "# Local config audit; no external chart commands.\n"
    )
    (root / "values/contracts-production.yaml").write_text(
        "configMaps:\n  env:\n    data:\n      L1_RPC_ENDPOINT: old\n      L2_RPC_ENDPOINT: old\n"
    )
    (root / "values/frontends-production.yaml").write_text(
        "ingress:\n  hosts:\n    - host: old\n      paths: []\n"
    )
    (root / "values/blockscout-production.yaml").write_text("""blockscout-stack:
      blockscout:
        ingress:
          hostname: old
        env:
          INDEXER_SCROLL_L1_RPC: old
      frontend:
        env:
          NEXT_PUBLIC_API_HOST: old
    """)
    (root / "values/frontends-config.yaml").write_text(
        'scrollConfig: |\n  REACT_APP_ETH_SYMBOL = "old"\n  REACT_APP_CONNECT_WALLET_PROJECT_ID = "old"\n'
    )
    for service in ["tso-service", "proof-coordinator"]:
        (root / f"values/{service}-production.yaml").write_text(
            "env: []\ningress:\n  main:\n    enabled: true\n    ingressClassName: nginx\n"
            "    hosts:\n      - host: old\n        paths:\n          - path: /\n            pathType: Prefix\n"
            f"    tls:\n      - hosts: [old]\n        secretName: {service}-tls\n"
        )
    # Native chart fixtures are prepared from Reth identities created by the CLI.
    for role in ["sequencer", "bootnode", "rpc"]:
        (root / f"values/l2-reth-{role}-production.yaml").write_text(
            f"role: {role}\nreth:\n  networkId: '221122'\n  trustedPeers: ''\n"
            "  l1Url: http://l1-interface:8545\n  signer:\n    type: none\n"
        )
    results = {}
    for command, args in [
        ("gen-keystore", []),
        (
            "l2-sequencer-reth",
            [
                "--index",
                "0",
                "--signer-mode",
                "external-secret",
                "--nodekey",
                "3" * 64,
                "--signer-private-key",
                TEST_KEY,
            ],
        ),
        (
            "l2-bootnode-reth",
            ["--count", "1", "--secret-mode", "external-secret", "--nodekey", "4" * 64],
        ),
        ("gen-secrets", []),
        ("domains", ["--no-bootstrap-tls"]),
        ("prep-charts", ["--skip-auth-check"]),
    ]:
        # Domains can fill defaults; remove the negative-control input immediately
        # before its consumer so this still tests missing RPC/DB propagation.
        if command == "prep-charts" and label == "missing-rpc":
            config_path = root / "config.toml"
            config_path.write_text("\n".join(
                line for line in config_path.read_text().splitlines()
                if not line.startswith("L2_RPC_ENDPOINT =")
            ) + "\n")
        with (root / (command + ".log")).open("w") as log:
            p = subprocess.run(
                [
                    "node",
                    str(cli / "bin/run.js"),
                    "setup",
                    command,
                    "-N",
                    "--json",
                    *args,
                ],
                cwd=root,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=90,
            )
        results[command] = p.returncode
        print(label, command, p.returncode, flush=True)
        if p.returncode:
            print((root / (command + ".log")).read_text()[-5000:], flush=True)
            break
    if not any(results.values()):
        names = [file.name for file in (root / "secrets").iterdir()]
        assert "l2-reth-sequencer-0-secret.env" in names
        assert "l2-reth-bootnode-0-secret.env" in names
        assert not any(
            name.startswith(("l2-sequencer-", "l2-bootnode-")) for name in names
        )
        reth_values = (root / "values/l2-reth-rpc-production.yaml").read_text()
        assert "l2-reth-sequencer-0:30303" in reth_values
        assert "@l2-sequencer-" not in reth_values
        config = tomllib.loads((root / "config.toml").read_text())
        for service, key in [("tso-service", "TSO_HOST"), ("proof-coordinator", "PROOF_COORDINATOR_HOST")]:
            host = config["ingress"][key]
            values = (root / f"values/{service}-production.yaml").read_text()
            assert f"host: {host}" in values, (service, host)
            assert f"- {host}" in values, (service, "TLS")
            assert "old" not in values, service

    (root / "results.json").write_text(json.dumps(results, indent=2))
    if any(results.values()):
        raise AssertionError(results)


def execute(stage, name, args, cwd=None):
    log = stage / "evidence" / (name + ".log")
    env = {
        **os.environ,
        "DEPLOYER_PRIVATE_KEY": TEST_KEY,
        "FOUNDRY_JOBS": "2",
        "RAYON_NUM_THREADS": "2",
    }
    with log.open("w") as output:
        result = subprocess.run(
            args,
            cwd=cwd or stage,
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=300,
        )
    if result.returncode:
        raise AssertionError(
            f"{name} failed ({result.returncode}); see {log}\n"
            + log.read_text()[-3000:]
        )


def fill_accounts(source):
    for key, value in {
        "DEPLOYER_PRIVATE_KEY": TEST_KEY,
        "DEPLOYER_ADDR": "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
        "OWNER_ADDR": "0x1111111111111111111111111111111111111111",
        "L2_GAS_ORACLE_SENDER_ADDR": "0x3333333333333333333333333333333333333333",
    }.items():
        source = source.replace(f'{key} = ""', f'{key} = "{value}"')
    return source.replace(
        'FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x0000000000000000000000000000000000000000"',
        'FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x2222222222222222222222222222222222222222"',
    )


def directory_contents(root):
    return {
        str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()
    }


def read_genesis(file):
    data = json.loads("\n".join(line[2:] for line in file.read_text().splitlines()[1:]))
    data.pop("timestamp")  # The generator deliberately uses the wall clock.
    return data


def flatten(config, prefix=""):
    result = {}
    for key, value in config.items():
        name = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            result.update(flatten(value, name))
        else:
            result[name] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli-repo", type=Path)
    parser.add_argument(
        "--baseline-ref", default="56a4cacda6046c9445af023aefee15a42fda2fdd"
    )
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--previous-evidence", type=Path,
                        help="Successful audit evidence from before contract script changes")
    parser.add_argument("--output", type=Path, help="New, empty evidence directory")
    args = parser.parse_args()
    contracts = Path(__file__).resolve().parents[2]
    cli = (args.cli_repo or contracts.parent / "scroll-sdk-cli").resolve()
    candidate = args.candidate or contracts / "docker/templates/config.toml"
    original = subprocess.check_output(
        ["git", "show", f"{args.baseline_ref}:docker/templates/config.toml"],
        cwd=contracts,
        text=True,
    )
    proposed = candidate.read_text()
    stage = (
        args.output.resolve()
        if args.output
        else Path(tempfile.mkdtemp(prefix="contracts-config-audit-"))
    )
    if args.output:
        stage.mkdir(parents=True, exist_ok=False)
    print(f"Evidence: {stage}", flush=True)
    for name in ["src", "scripts", "docker", "artifacts", "cache"]:
        if (contracts / name).exists():
            shutil.copytree(contracts / name, stage / name)
    for name in ["foundry.toml", "remappings.txt", "package.json"]:
        shutil.copy2(contracts / name, stage / name)
    for name in ["lib", "node_modules"]:
        (stage / name).symlink_to(contracts / name, target_is_directory=True)
    (stage / "volume").mkdir()
    evidence = stage / "evidence"
    evidence.mkdir()
    before = flatten(tomllib.loads(original))
    after = flatten(tomllib.loads(proposed))
    (evidence / "template-diff.json").write_text(
        json.dumps(
            {
                "removed": sorted(before.keys() - after.keys()),
                "added": sorted(after.keys() - before.keys()),
            },
            indent=2,
        )
    )
    for label, template in [("baseline", original), ("candidate", proposed)]:
        (evidence / f"config.{label}.toml").write_text(template)
        (stage / "volume/config.toml").write_text(fill_accounts(template))
        execute(stage, label + "-generation", ["bash", "docker/scripts/gen-configs.sh"])
        deploy_locally(stage, label)
        run_cli(stage, cli, label)
    # Retired frontend projections must disappear with both legacy and new inputs.
    for label in ["baseline", "candidate"]:
        frontend = (evidence / label / "frontend-config.yaml").read_text()
        assert "REACT_APP_BRIDGE_API_URI" not in frontend
        root_config = (evidence / f"cli-{label}" / "config.toml").read_text()
        assert "rollup" not in tomllib.loads(root_config), label
        for retired in ["BRIDGE_API_URI", "BRIDGE_HISTORY_API_HOST",
                        "BRIDGE_HISTORY_DB_CONNECTION_STRING",
                        "CHAIN_MONITOR_DB_CONNECTION_STRING",
                        "L1_EXPLORER_DB_CONNECTION_STRING", "ROLLUP_EXPLORER_API_HOST",
                        "COORDINATOR_API_HOST", "ADMIN_SYSTEM_DASHBOARD_HOST",
                        "L1_EXPLORER_HOST", "BLOCKSCOUT_BACKEND_HOST"]:
            assert retired not in root_config, (label, retired)
    for name in ["config-contracts.toml", "frontend-config.yaml", "onchain.json"]:
        assert (evidence / "baseline" / name).read_bytes() == (
            evidence / "candidate" / name
        ).read_bytes(), name
    assert read_genesis(evidence / "baseline/genesis.yaml") == read_genesis(
        evidence / "candidate/genesis.yaml"
    )
    if args.previous_evidence:
        previous = args.previous_evidence.resolve() / "candidate"
        for name in ["config-contracts.toml", "frontend-config.yaml", "onchain.json"]:
            assert (previous / name).read_bytes() == (evidence / "candidate" / name).read_bytes(), ("previous scripts", name)
        assert read_genesis(previous / "genesis.yaml") == read_genesis(evidence / "candidate/genesis.yaml"), "previous scripts genesis"
    for name in ["secrets", "values"]:
        assert directory_contents(
            evidence / "cli-baseline" / name
        ) == directory_contents(evidence / "cli-candidate" / name), name

    # A zero exit status alone does not detect silently missing chart/secret values.
    for label, key, output in [
        ("missing-rpc", "L2_RPC_ENDPOINT", "values"),
        ("missing-db", "BLOCKSCOUT_DB_CONNECTION_STRING", "secrets"),
    ]:
        destination = evidence / label
        destination.mkdir()
        config = (evidence / "candidate/config.toml").read_text()
        config = (
            "\n".join(
                line for line in config.splitlines() if not line.startswith(key + " =")
            )
            + "\n"
        )
        (destination / "config.toml").write_text(config)
        shutil.copy2(
            evidence / "candidate/config-contracts.toml",
            destination / "config-contracts.toml",
        )
        run_cli(stage, cli, label)
        assert directory_contents(
            evidence / "cli-candidate" / output
        ) != directory_contents(evidence / ("cli-" + label) / output), label

    original_config = (stage / "volume/config.toml").read_text()
    for key in [
        "L2_GAS_ORACLE_SENDER_ADDR",
        "L2_NATIVE_DOGE_TOKEN",
        "SCALAR",
        "GRAFANA_URI",
    ]:
        try:
            (stage / "volume/config.toml").write_text(
                "\n".join(
                    line
                    for line in original_config.splitlines()
                    if not line.startswith(key + " =")
                )
                + "\n"
            )
            try:
                execute(
                    stage, "missing-" + key, ["bash", "docker/scripts/gen-configs.sh"]
                )
            except AssertionError:
                log = (evidence / ("missing-" + key + ".log")).read_text()
                assert (
                    key in log
                ), f"Negative control failed for an unrelated reason: {key}"
            else:
                raise AssertionError(
                    f"Missing required field unexpectedly accepted: {key}"
                )
        finally:
            (stage / "volume/config.toml").write_text(original_config)

    (stage / "docker/templates/config.toml").write_text(proposed)
    execute(
        stage, "verification-tests", ["node", "--test", "docker/scripts/verify.test.js"]
    )
    execute(
        stage,
        "foundry-tests",
        [
            "forge",
            "test",
            "--match-contract",
            "GenerateGenesisTest|FeeOracleAddressConfigurationTest",
        ],
    )
    execute(
        stage,
        "cli-tests",
        [str(cli / "node_modules/.bin/mocha"), "--forbid-only", "test/**/*.test.ts"],
        cwd=cli,
    )
    onchain = json.loads((evidence / "candidate/onchain.json").read_text())
    summary = {
        "success": True,
        "baseline_ref": args.baseline_ref,
        "previous_evidence_compared": str(args.previous_evidence) if args.previous_evidence else None,
        "runtime_bytecodes_compared": len(onchain["code"]),
        "onchain_state_reads_compared": len(onchain["state"]),
        "secret_files_compared": len(
            directory_contents(evidence / "cli-candidate/secrets")
        ),
        "values_files_compared": len(
            directory_contents(evidence / "cli-candidate/values")
        ),
        "verification": "local script tests; external explorer requests mocked",
        "deployment": "actual transactions to two temporary local Anvil chains",
    }
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
