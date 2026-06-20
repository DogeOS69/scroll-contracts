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

# Submits ProxyAdmin.upgrade(messengerProxy, newImpl) from the ProxyAdmin owner.
# After this upgrade the Moat is the ONLY address allowed to send L2->L1
# messages, so the fee vault MUST already be rewired through the
# FeeVaultMoatAdapter (submit-fee-vault-rewire.sh) — this script refuses to
# broadcast otherwise.
#
# RPC from volume/config.toml, addresses from volume/config-contracts.toml
# (refreshed by deploy-dogeos-messenger-impl.sh).
# Inputs:
#   BROADCAST=1             actually send the upgrade tx (otherwise preflight only)
#   OWNER_PRIVATE_KEY=0x... ProxyAdmin owner key — required only when BROADCAST=1.

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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

require_file "$CONFIG"
require_file "$CONFIG_CONTRACTS"
require_command cast

L2_RPC_ENDPOINT=$(extract EXTERNAL_RPC_URI_L2 "$CONFIG")
L2_PROXY_ADMIN_ADDR=$(extract L2_PROXY_ADMIN_ADDR "$CONFIG_CONTRACTS")
L2_DOGEOS_MESSENGER_PROXY_ADDR=$(extract L2_DOGEOS_MESSENGER_PROXY_ADDR "$CONFIG_CONTRACTS")
L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR=$(extract L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR "$CONFIG_CONTRACTS")
L2_TX_FEE_VAULT_ADDR=$(extract L2_TX_FEE_VAULT_ADDR "$CONFIG_CONTRACTS")
L2_FEE_VAULT_MOAT_ADAPTER_ADDR=$(extract L2_FEE_VAULT_MOAT_ADAPTER_ADDR "$CONFIG_CONTRACTS")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
require_non_empty "L2_PROXY_ADMIN_ADDR in $CONFIG_CONTRACTS" "$L2_PROXY_ADMIN_ADDR"
require_non_empty "L2_DOGEOS_MESSENGER_PROXY_ADDR in $CONFIG_CONTRACTS" "$L2_DOGEOS_MESSENGER_PROXY_ADDR"
require_non_empty "L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR in $CONFIG_CONTRACTS" "$L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR"
require_non_empty "L2_TX_FEE_VAULT_ADDR in $CONFIG_CONTRACTS" "$L2_TX_FEE_VAULT_ADDR"
require_non_empty "L2_FEE_VAULT_MOAT_ADAPTER_ADDR in $CONFIG_CONTRACTS" "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR"

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "running preflight checks"
require_contract_code "$L2_PROXY_ADMIN_ADDR" "L2_PROXY_ADMIN_ADDR"
require_contract_code "$L2_DOGEOS_MESSENGER_PROXY_ADDR" "L2_DOGEOS_MESSENGER_PROXY_ADDR"
require_contract_code "$L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR" "L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR"

echo "RPC:             $L2_RPC_ENDPOINT"
echo "ProxyAdmin:      $L2_PROXY_ADMIN_ADDR"
echo "Messenger proxy: $L2_DOGEOS_MESSENGER_PROXY_ADDR"
echo "Target impl:     $L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR"
PROXY_ADMIN_OWNER=$(cast call "$L2_PROXY_ADMIN_ADDR" 'owner()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "ProxyAdmin owner: $PROXY_ADMIN_OWNER"

IMPL_BEFORE=$(cast implementation "$L2_DOGEOS_MESSENGER_PROXY_ADDR" --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "impl before: $IMPL_BEFORE"
if [ "$(lower "$IMPL_BEFORE")" = "$(lower "$L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR")" ]; then
    echo "warning: target implementation is already active on proxy"
fi

# Ordering guard: after this upgrade the fee vault can no longer send L2->L1
# messages directly. Refuse to broadcast unless the vault is already routed
# through the adapter.
VAULT_MESSENGER=$(cast call "$L2_TX_FEE_VAULT_ADDR" 'messenger()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "fee vault messenger: $VAULT_MESSENGER"
if [ "$(lower "$VAULT_MESSENGER")" != "$(lower "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR")" ]; then
    echo ""
    echo "fee vault is NOT routed through the FeeVaultMoatAdapter yet."
    echo "run submit-fee-vault-rewire.sh first — upgrading now would make fee"
    echo "vault withdrawals revert until the vault is repointed."
    if [ "${FORCE:-0}" != "1" ]; then
        exit 1
    fi
    echo "FORCE=1 set — continuing anyway"
fi

snapshot() {
    printf "%-22s %s\n" "$1" "$(cast call "$L2_DOGEOS_MESSENGER_PROXY_ADDR" "$2" --rpc-url "$L2_RPC_ENDPOINT")"
}

echo ""
echo "pre-upgrade storage snapshot"
snapshot "MOAT:"        'MOAT()(address)'
snapshot "counterpart:" 'counterpart()(address)'
snapshot "paused:"      'paused()(bool)'

if [ "${BROADCAST:-0}" = "1" ]; then
    if [ "$OWNER_PRIVATE_KEY" = "" ]; then
        echo "OWNER_PRIVATE_KEY is not set for broadcast"
        exit 1
    fi
    require_command forge

    echo ""
    echo "broadcasting ProxyAdmin.upgrade on L2 via forge script"
    forge script scripts/deterministic/SubmitProxyUpgrades.s.sol:SubmitDogeOsMessengerProxyUpgrade \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --legacy \
        --broadcast

    echo "impl after:  $(cast implementation "$L2_DOGEOS_MESSENGER_PROXY_ADDR" --rpc-url "$L2_RPC_ENDPOINT")"
else
    echo ""
    echo "preflight only — set BROADCAST=1 to execute upgrade"
fi
