#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ "$REPO_ROOT" = "" ]; then
    REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
fi

VOLUME_PATH="$REPO_ROOT/volume"
if [ ! -e "$VOLUME_PATH" ]; then
    echo "missing volume path: $VOLUME_PATH"
    echo "hint: create $VOLUME_PATH with config.toml and config-contracts.toml"
    exit 1
fi

export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"
CONFIG="$VOLUME_PATH/config.toml"
CONFIG_CONTRACTS="$VOLUME_PATH/config-contracts.toml"

extract() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$2"; }
extract_number() { sed -n "s/^$1 *= *\([0-9_][0-9_]*\).*/\1/p" "$2"; }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1"
        exit 1
    fi
}

require_non_empty() {
    if [ "$2" = "" ]; then
        echo "$1 is not set"
        exit 1
    fi
}

require_contract_code() {
    code=$(cast code "$1" --rpc-url "$L2_RPC_ENDPOINT") || exit 1
    if [ "$code" = "0x" ]; then
        echo "$2 has no deployed code at $1"
        exit 1
    fi
}

require_file() {
    if [ ! -f "$1" ]; then
        echo "missing file: $1"
        exit 1
    fi
}

require_file "$CONFIG"
require_file "$CONFIG_CONTRACTS"
require_command forge
require_command cast

L2_RPC_ENDPOINT=$(extract EXTERNAL_RPC_URI_L2 "$CONFIG")
L2_PROXY_ADMIN_ADDR=$(extract L2_PROXY_ADMIN_ADDR "$CONFIG_CONTRACTS")
L2_MOAT_PROXY_ADDR=$(extract L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
CHAIN_ID_L1=$(extract_number CHAIN_ID_L1 "$CONFIG")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
require_non_empty "L2_PROXY_ADMIN_ADDR in $CONFIG_CONTRACTS" "$L2_PROXY_ADMIN_ADDR"
require_non_empty "L2_MOAT_PROXY_ADDR in $CONFIG_CONTRACTS" "$L2_MOAT_PROXY_ADDR"
require_non_empty "CHAIN_ID_L1 in $CONFIG" "$CHAIN_ID_L1"

cd "$REPO_ROOT"

echo "using REPO_ROOT = $REPO_ROOT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"
echo "using CHAIN_ID_L1 = $CHAIN_ID_L1"

case "$CHAIN_ID_L1" in
    1|111_111|111111|5_555_555|5555555) ;;
    *)
        echo "unsupported CHAIN_ID_L1=$CHAIN_ID_L1 for Moat Dogecoin prefix selection"
        exit 1
        ;;
esac

echo ""
echo "running preflight checks"
echo "ProxyAdmin: $L2_PROXY_ADMIN_ADDR"
echo "Moat proxy: $L2_MOAT_PROXY_ADDR"
require_contract_code "$L2_PROXY_ADMIN_ADDR" "L2_PROXY_ADMIN_ADDR"
require_contract_code "$L2_MOAT_PROXY_ADDR" "L2_MOAT_PROXY_ADDR"
IMPL_BEFORE=$(cast implementation "$L2_MOAT_PROXY_ADDR" --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "impl before: $IMPL_BEFORE"

# Inputs:
#   BROADCAST=1             actually send the deploy tx (otherwise preflight/simulation only)
#
# This script ONLY deploys a new Moat implementation. It does not upgrade the
# proxy — the ProxyAdmin owner must submit the upgrade() call separately. The
# simulate/broadcast output prints the exact calldata to submit.
#
# Addresses (L2_MOAT_PROXY_ADDR, L2_PROXY_ADMIN_ADDR) are read from
# volume/config-contracts.toml. RPC and CHAIN_ID_L1 come from config.toml.
# Dogecoin prefixes are auto-selected via _dogePrefixesFromL1ChainId().

# Simulate first (always).
echo ""
echo "simulating Moat implementation deploy on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll \
    --rpc-url "$L2_RPC_ENDPOINT" \
    --sig "deployL2MoatImpl(string,string)" "L2" "write-config" \
    --legacy

# Only broadcast if explicitly requested.
if [ "${BROADCAST:-0}" = "1" ]; then
    echo ""
    echo "broadcasting Moat implementation deploy on L2"
    forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --sig "deployL2MoatImpl(string,string)" "L2" "write-config" \
        --legacy \
        --broadcast
else
    echo ""
    echo "preflight/simulation only — set BROADCAST=1 to execute deploy"
fi
