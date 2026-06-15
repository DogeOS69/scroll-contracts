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
    echo "hint: ln -sfn ../dogeos-aws-devnet $VOLUME_PATH"
    exit 1
fi

if [ ! -L "$VOLUME_PATH" ]; then
    echo "warning: $VOLUME_PATH is not a symlink"
fi

# Submits ProxyAdmin.upgrade(moatProxy, newImpl) from the ProxyAdmin owner.
# RPC from volume/config.toml, addresses from volume/config-contracts.toml
# (both refreshed by deploy-moat-impl.sh).
# Inputs:
#   BROADCAST=1             actually send the upgrade tx (otherwise preflight only)
#   OWNER_PRIVATE_KEY=0x... ProxyAdmin owner key — required only when BROADCAST=1.
#                           Pass via env (e.g. `OWNER_PRIVATE_KEY=... BROADCAST=1 ...`)
#                           — do not hardcode into a tracked file.

OWNER_PRIVATE_KEY="${OWNER_PRIVATE_KEY:-}"
CONFIG="$VOLUME_PATH/config.toml"
CONFIG_CONTRACTS="$VOLUME_PATH/config-contracts.toml"

extract() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$2"; }

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
require_command cast

L2_RPC_ENDPOINT=$(extract EXTERNAL_RPC_URI_L2 "$CONFIG")
L2_PROXY_ADMIN_ADDR=$(extract L2_PROXY_ADMIN_ADDR "$CONFIG_CONTRACTS")
L2_MOAT_PROXY_ADDR=$(extract L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
L2_MOAT_IMPLEMENTATION_ADDR=$(extract L2_MOAT_IMPLEMENTATION_ADDR "$CONFIG_CONTRACTS")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
require_non_empty "L2_PROXY_ADMIN_ADDR in $CONFIG_CONTRACTS" "$L2_PROXY_ADMIN_ADDR"
require_non_empty "L2_MOAT_PROXY_ADDR in $CONFIG_CONTRACTS" "$L2_MOAT_PROXY_ADDR"
require_non_empty "L2_MOAT_IMPLEMENTATION_ADDR in $CONFIG_CONTRACTS" "$L2_MOAT_IMPLEMENTATION_ADDR"

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "running preflight checks"
require_contract_code "$L2_PROXY_ADMIN_ADDR" "L2_PROXY_ADMIN_ADDR"
require_contract_code "$L2_MOAT_PROXY_ADDR" "L2_MOAT_PROXY_ADDR"
require_contract_code "$L2_MOAT_IMPLEMENTATION_ADDR" "L2_MOAT_IMPLEMENTATION_ADDR"

echo "RPC:        $L2_RPC_ENDPOINT"
echo "ProxyAdmin: $L2_PROXY_ADMIN_ADDR"
echo "Moat proxy: $L2_MOAT_PROXY_ADDR"
echo "Target impl:$L2_MOAT_IMPLEMENTATION_ADDR"
PROXY_ADMIN_OWNER=$(cast call "$L2_PROXY_ADMIN_ADDR" 'owner()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "ProxyAdmin owner: $PROXY_ADMIN_OWNER"

IMPL_BEFORE=$(cast implementation "$L2_MOAT_PROXY_ADDR" --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "impl before: $IMPL_BEFORE"
if [ "$(printf '%s' "$IMPL_BEFORE" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$L2_MOAT_IMPLEMENTATION_ADDR" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "warning: target implementation is already active on proxy"
fi

snapshot() {
    printf "%-22s %s\n" "$1" "$(cast call "$L2_MOAT_PROXY_ADDR" "$2" --rpc-url "$L2_RPC_ENDPOINT")"
}

echo ""
echo "pre-upgrade storage snapshot"
snapshot "messenger:"           'messenger()(address)'
snapshot "withdrawalFee:"       'withdrawalFee()(uint256)'
snapshot "minWithdrawalAmount:" 'minWithdrawalAmount()(uint256)'
snapshot "depositFee:"          'depositFee()(uint256)'
snapshot "feeRecipient:"        'feeRecipient()(address)'
snapshot "owner:"               'owner()(address)'

if [ "${BROADCAST:-0}" = "1" ]; then
    if [ "$OWNER_PRIVATE_KEY" = "" ]; then
        echo "OWNER_PRIVATE_KEY is not set for broadcast"
        exit 1
    fi

    echo ""
    echo "broadcasting ProxyAdmin.upgrade on L2"
    cast send "$L2_PROXY_ADMIN_ADDR" \
        'upgrade(address,address)' \
        "$L2_MOAT_PROXY_ADDR" "$L2_MOAT_IMPLEMENTATION_ADDR" \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --private-key "$OWNER_PRIVATE_KEY" \
        --legacy

    echo "impl after:  $(cast implementation "$L2_MOAT_PROXY_ADDR" --rpc-url "$L2_RPC_ENDPOINT")"
else
    echo ""
    echo "preflight only — set BROADCAST=1 to execute upgrade"
fi
