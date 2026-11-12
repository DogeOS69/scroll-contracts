#!/usr/bin/env python3
"""Check that each testnet L2 proxy can be upgraded from what it runs today to this tree.

One-off for the testnet upgrade (see README.md next to this file). It removes nothing
from, and adds nothing to, scripts/check-storage-layout.py, which pins the layout of
this tree; this script instead compares this tree against the layout of the
implementation testnet actually runs.

`deployed-layouts/<Contract>.json` holds that layout, in the same format as
storage-layouts/, generated from the commit whose runtime bytecode equals the
deployed implementation (README.md records the commit and the code hashes).

An upgrade keeps the proxy's storage, so for every contract:

  * each deployed variable must still be at the same slot and offset with the same
    type, in the same order; a label may change only through RENAMES below;
  * new variables may only follow the last deployed one;
  * every struct the deployed storage reaches must keep its member layout.

    python3 scripts/testnet-upgrade/check-upgrade-layout.py
"""

import importlib.util
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent

CONTRACTS = (
    "src/dogeos/L2DogeOsMessenger.sol:L2DogeOsMessenger",
    "src/dogeos/Moat.sol:Moat",
)

# Intended renames of a deployed variable that keeps its slot, offset and type.
RENAMES = {
    # The messenger became an immutable (Moat.MESSENGER); the old slot keeps its value.
    ("src/dogeos/Moat.sol:Moat", "messenger"): "_deprecatedMessengerSlot",
}


def load_layout_tool():
    spec = importlib.util.spec_from_file_location("check_storage_layout", REPO_ROOT / "scripts" / "check-storage-layout.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compare(identifier, deployed, current):
    """Return the list of problems upgrading `deployed` to `current`."""
    problems = []
    old, new = deployed["storage"], current["storage"]
    if len(new) < len(old):
        problems.append(f"{len(old) - len(new)} deployed variable(s) removed")
    for index, before in enumerate(old[: len(new)]):
        after = new[index]
        where = f"entry {index} (slot {before['slot']}, offset {before['offset']})"
        for field in ("slot", "offset", "type"):
            if before[field] != after[field]:
                problems.append(f"{where}: {field} {before[field]!r} -> {after[field]!r}")
        expected_label = RENAMES.get((identifier, before["label"]), before["label"])
        if after["label"] != expected_label:
            problems.append(f"{where}: label {before['label']!r} -> {after['label']!r} (not in RENAMES)")
    for name, members in deployed["structs"].items():
        if current["structs"].get(name) != members:
            problems.append(f"struct {name}: member layout changed")
    return problems


def main():
    tool = load_layout_tool()
    failures = []
    for identifier in CONTRACTS:
        name = identifier.rsplit(":", 1)[1]
        deployed = json.loads((HERE / "deployed-layouts" / f"{name}.json").read_text())
        if deployed["contract"] != identifier:
            sys.exit(f"deployed-layouts/{name}.json is for {deployed['contract']}, expected {identifier}")
        current = json.loads(tool.inspect_layout(identifier))
        problems = compare(identifier, deployed, current)
        appended = [entry["label"] for entry in current["storage"][len(deployed["storage"]) :]]
        if problems:
            failures.append(f"{name}: NOT upgrade-compatible\n  " + "\n  ".join(problems))
        else:
            print(f"{name}: upgrade-compatible ({len(deployed['storage'])} deployed variables kept, appended: {appended or 'none'})")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
