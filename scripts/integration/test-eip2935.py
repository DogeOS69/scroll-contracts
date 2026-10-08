#!/usr/bin/env python3
"""Check actual generated genesis; optionally test it with the DogeOS geth executor.

Requires forge, jq, and installed repo dependencies. The geth execution test
additionally requires Go and a DogeOS geth checkout.
No running network or user volume/config.toml is accessed.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

GETH_REVISION = "33c46866196da34484bf1bfbaab20aa4929b3fcc"
TEST_KEY = "0x" + "0" * 63 + "1"
TEST_ADDRESS = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
HISTORY_ADDRESS = "0x0000f90827f1c53a10cb7a02335b175320002935"
HISTORY_CODE = (
    "0x3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f"
    "35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f"
    "5ffd5b5f35611fff60014303065500"
)


def verify_genesis(genesis_path):
    # Match the externally consumed artifact, including the Docker entrypoint's
    # ConfigMap/YAML wrapping. The intermediate Forge output alone is not enough.
    lines = genesis_path.read_text().splitlines()
    if not lines or lines[0] != "scrollConfig: |" or any(not line.startswith("  ") for line in lines[1:]):
        raise RuntimeError("gen-configs entrypoint did not produce the expected genesis.yaml wrapper")
    genesis = json.loads("\n".join(line[2:] for line in lines[1:]))
    if genesis["config"].get("feynmanTime") != 0:
        raise RuntimeError("expected the Feynman-at-genesis fork configuration")
    account = genesis["alloc"].get(HISTORY_ADDRESS)
    if account is None:
        raise RuntimeError("generated genesis is missing the EIP-2935 history account")
    if account["code"].lower() != HISTORY_CODE:
        raise RuntimeError("generated genesis history runtime is not canonical")
    if int(str(account["nonce"]), 0) != 1 or int(str(account["balance"]), 0) != 0:
        raise RuntimeError("generated genesis history account must have nonce 1 and balance 0")
    if account["storage"] != {}:
        raise RuntimeError("generated genesis history storage must be empty")
    print("Generated genesis: canonical EIP-2935 runtime, nonce 1, balance 0, empty storage", flush=True)
    return genesis


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--genesis-only", action="store_true", help="check generated alloc without a client checkout")
    mode.add_argument("--geth-repo", type=Path, help="also run the pinned geth execution test")
    args = parser.parse_args()
    geth = args.geth_repo.resolve() if args.geth_repo else None
    if geth:
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=geth, text=True).strip()
        if revision != GETH_REVISION:
            parser.error(f"expected DogeOS geth revision {GETH_REVISION}; found {revision}")
        subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", "*.go", "go.mod", "go.sum"], cwd=geth, check=True)
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="eip2935-genesis-") as directory:
        stage = Path(directory)
        for name in ["src", "scripts", "docker", "lib", "node_modules", "foundry.toml", "remappings.txt"]:
            (stage / name).symlink_to(root / name)
        (stage / "volume").mkdir()
        config = (root / "docker/templates/config.toml").read_text()
        for name, value in {
            "DEPLOYER_PRIVATE_KEY": TEST_KEY,
            "DEPLOYER_ADDR": TEST_ADDRESS,
            "OWNER_ADDR": TEST_ADDRESS,
            "L2_GAS_ORACLE_SENDER_ADDR": "0x0000000000000000000000000000000000001234",
        }.items():
            config = config.replace(f'{name} = ""', f'{name} = "{value}"')
        (stage / "volume/config.toml").write_text(config)
        env = dict(os.environ, DEPLOYER_PRIVATE_KEY=TEST_KEY)
        # Run exactly the gen-configs image ENTRYPOINT, including frontend output.
        subprocess.run(["bash", "docker/scripts/gen-configs.sh"], cwd=stage, env=env, check=True)
        genesis_path = stage / "volume/genesis.yaml"
        genesis = verify_genesis(genesis_path)
        if not (stage / "volume/config-contracts.toml").is_file():
            raise RuntimeError("gen-configs entrypoint did not export contract addresses")
        if not (stage / "volume/frontend-config.yaml").read_text().startswith("scrollConfig: |\n"):
            raise RuntimeError("gen-configs entrypoint did not export wrapped frontend configuration")
        if not geth:
            return
        # geth accepts the JSON payload, not the Kubernetes ConfigMap wrapper.
        json_path = stage / "volume/genesis.json"
        json_path.write_text(json.dumps(genesis))
        env["GENESIS_PATH"] = str(json_path)
        subprocess.run(
            ["go", "test", str(root / "scripts/integration/eip2935_geth_test.go"), "-v", "-count=1"],
            cwd=geth, env=env, check=True,
        )


if __name__ == "__main__":
    main()
