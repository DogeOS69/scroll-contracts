#!/usr/bin/env python3
"""Pin the storage layout of the upgradeable and predeployed DogeOS L2 contracts.

Both of the ways DogeOS puts code on L2 keep storage across a code change, so a
variable that silently moves corrupts live state:

  * the contracts behind the L2 ProxyAdmin keep the proxy's storage across an
    implementation upgrade (scripts/deterministic/DeployScroll.s.sol, "L2" mode);
  * the genesis predeploys get their code etched and a few slots written by
    absolute slot number (scripts/deterministic/GenerateGenesis.s.sol).

`storage-layouts/<Contract>.json` records the committed layout of each of them:
one ordered entry per variable with its label, slot, offset and type label, as
reported by `forge inspect <Contract> storageLayout`. AST ids are dropped,
because they shift whenever an unrelated source file changes.

A type label fixes the width of its variable, so a packing change or a resized
gap moves a slot or an offset in `storage`. What a label does not describe is
the member layout of a struct: a member that moves inside a struct changes where
the contract reads data it already holds, even when every surrounding variable
stays put. So each snapshot also carries a `structs` section with the member
label, slot, offset and type label of every struct the storage reaches, mapping
and array values included.

Check the committed layouts (what CI runs):

    python3 scripts/check-storage-layout.py

Rewrite them after an intended layout change, and commit the diff:

    python3 scripts/check-storage-layout.py --write
"""

import argparse
import difflib
import json
import pathlib
import re
import subprocess
import sys

# Every contract the DogeOS L2 deployment either puts behind the L2 ProxyAdmin or
# installs as a genesis predeploy. "proxy" contracts are deployed by
# DeployScroll's deployL2Contracts1stPass/2ndPass and upgraded through
# L2_PROXY_ADMIN_ADDR; "predeploy" contracts are etched by GenerateGenesis's
# generateGenesisAlloc, which also writes some of their slots by number.
# The legacy Scroll asset gateways, the gateway router and the ERC20
# factory/template are not deployed on DogeOS and are not listed.
CONTRACTS = (
    # behind the L2 ProxyAdmin
    "src/dogeos/Moat.sol:Moat",
    "src/dogeos/L2DogeOsMessenger.sol:L2DogeOsMessenger",
    "src/L2/L2SystemConfig.sol:L2SystemConfig",
    # genesis predeploys
    "src/L2/predeploys/L2MessageQueue.sol:L2MessageQueue",
    "src/L2/predeploys/L1GasPriceOracle.sol:L1GasPriceOracle",
    "src/L2/predeploys/L2TxFeeVault.sol:L2TxFeeVault",
    "src/L2/predeploys/Whitelist.sol:Whitelist",
    "src/dogeos/WrappedDoge.sol:WrappedDoge",
    "src/dogeos/NativeDogeToken.sol:NativeDogeToken",
)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
LAYOUT_DIR = REPO_ROOT / "storage-layouts"
EVM_VERSION = "cancun"

# solc names a struct, contract, enum or user-defined value type after the AST node
# that declares it, as in `t_struct(Counter)953_storage`. Only those four carry an id;
# the digits in `t_array(t_uint256)80_storage` are an array length, not an id.
TYPE_ID = re.compile(r"(t_(?:struct|contract|enum|userDefinedValueType)\([^)]*\))\d+")


def strip_type_ids(type_key):
    return TYPE_ID.sub(r"\1", type_key)


def rekey_types(types):
    """Re-key solc's type table by stripped type key, refusing to merge two types."""
    stripped = {}
    for key, value in types.items():
        previous = stripped.setdefault(strip_type_ids(key), value)
        if previous is not value and previous != value:
            raise RuntimeError(f"two different types share the key {strip_type_ids(key)!r}")
    return stripped


def collect_structs(types, type_key, structs, seen):
    """Record the member layout of every struct reachable from `type_key`.

    `types` is keyed by stripped type key; the references inside each entry still
    carry their ids, so every one is stripped before it is looked up.
    """
    entry = types[type_key]
    members = [
        {
            "label": member["label"],
            "slot": int(member["slot"]),
            "offset": int(member["offset"]),
            "type": types[strip_type_ids(member["type"])]["label"],
        }
        for member in entry.get("members", [])
    ]
    if "members" in entry:
        label = entry["label"]
        if structs.setdefault(label, members) != members:
            raise RuntimeError(f"two different structs share the label {label!r}")
    # A struct can hold another struct, and a mapping or array can hold either.
    children = [entry[part] for part in ("base", "key", "value") if part in entry]
    children += [member["type"] for member in entry.get("members", [])]
    for child in children:
        child = strip_type_ids(child)
        if child not in seen:
            seen.add(child)
            collect_structs(types, child, structs, seen)


def normalize(identifier, layout):
    """Return the committed JSON text for one `forge inspect storageLayout` output."""
    try:
        types = rekey_types(layout["types"] or {})
        entries = []
        structs = {}
        for entry in layout["storage"]:
            type_key = strip_type_ids(entry["type"])
            entries.append(
                {
                    "label": entry["label"],
                    "slot": int(entry["slot"]),
                    "offset": int(entry["offset"]),
                    "type": types[type_key]["label"],
                }
            )
            collect_structs(types, type_key, structs, {type_key})
    except (KeyError, TypeError, ValueError) as error:
        raise RuntimeError(f"forge inspect {identifier}: unexpected output ({error})") from error
    snapshot = {"contract": identifier, "storage": entries, "structs": dict(sorted(structs.items()))}
    return json.dumps(snapshot, indent=2) + "\n"


def inspect_layout(identifier):
    """Return the normalized layout `forge` reports for one contract."""
    raw = subprocess.run(
        ["forge", "inspect", identifier, "storageLayout", "--json", "--evm-version", EVM_VERSION],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if raw.returncode != 0:
        raise RuntimeError(f"forge inspect {identifier}: {raw.stderr.strip() or raw.stdout.strip()}")
    try:
        layout = json.loads(raw.stdout)
    except ValueError as error:
        raise RuntimeError(f"forge inspect {identifier}: unexpected output ({error})") from error
    return normalize(identifier, layout)


def snapshot_path(identifier):
    return LAYOUT_DIR / f"{identifier.rsplit(':', 1)[1]}.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true", help="rewrite the committed layouts instead of checking them")
    args = parser.parse_args()

    expected = {snapshot_path(identifier): identifier for identifier in CONTRACTS}
    failures = []

    if args.write:
        LAYOUT_DIR.mkdir(exist_ok=True)
    elif not LAYOUT_DIR.is_dir():
        raise RuntimeError(f"missing layout directory {LAYOUT_DIR.relative_to(REPO_ROOT)}")

    # A snapshot of a contract no longer listed above would never be checked again.
    for stale in sorted(set(LAYOUT_DIR.glob("*.json")) - set(expected)):
        failures.append(f"{stale.relative_to(REPO_ROOT)}: not a pinned contract; delete it or add it to CONTRACTS")

    for path, identifier in expected.items():
        current = inspect_layout(identifier)
        if args.write:
            path.write_text(current)
            print(f"wrote {path.relative_to(REPO_ROOT)}")
            continue
        committed = path.read_text() if path.is_file() else ""
        if committed == current:
            print(f"{identifier}: layout unchanged")
            continue
        diff = difflib.unified_diff(
            committed.splitlines(keepends=True),
            current.splitlines(keepends=True),
            fromfile=f"committed {path.relative_to(REPO_ROOT)}",
            tofile=f"current {identifier}",
        )
        failures.append(f"{identifier}: storage layout changed\n" + "".join(diff))

    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise RuntimeError(
            "storage layout no longer matches the committed pins; if the change is intended, "
            "rerun with --write and commit the diff"
        )


if __name__ == "__main__":
    main()
