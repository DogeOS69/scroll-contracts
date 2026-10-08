#!/usr/bin/env python3
"""Generate a disposable genesis and test it with the audited DogeOS geth executor.

Requires forge, jq, Go, installed repo dependencies, and a DogeOS geth checkout.
No running network or user volume/config.toml is accessed.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

GETH_REVISION = "33c46866196da34484bf1bfbaab20aa4929b3fcc"
TEST_KEY = "0x" + "0" * 63 + "1"
TEST_ADDRESS = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--geth-repo", type=Path, required=True)
    args = parser.parse_args()
    geth = args.geth_repo.resolve()
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
        for script, arguments in [
            ("DeployScroll", ["--sig", "run(string,string)", "none", "write-config"]),
            ("GenerateGenesis", ["--sig", "run()"]),
        ]:
            subprocess.run(
                ["forge", "script", f"scripts/deterministic/{script}.s.sol:{script}", *arguments],
                cwd=stage, env=env, check=True,
            )
        env["GENESIS_PATH"] = str(stage / "volume/genesis.yaml")
        subprocess.run(
            ["go", "test", str(root / "scripts/integration/eip2935_geth_test.go"), "-v", "-count=1"],
            cwd=geth, env=env, check=True,
        )


if __name__ == "__main__":
    main()
