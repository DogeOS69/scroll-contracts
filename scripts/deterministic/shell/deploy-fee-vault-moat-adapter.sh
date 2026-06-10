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

export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"
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
require_command forge
require_command cast

L2_RPC_ENDPOINT=$(extract EXTERNAL_RPC_URI_L2 "$CONFIG")
L2_TX_FEE_VAULT_ADDR=$(extract L2_TX_FEE_VAULT_ADDR "$CONFIG_CONTRACTS")
L2_MOAT_PROXY_ADDR=$(extract L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
FEE_VAULT_DOGE_RECIPIENT_ADDR=$(extract FEE_VAULT_DOGE_RECIPIENT_ADDR "$CONFIG")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
require_non_empty "L2_TX_FEE_VAULT_ADDR in $CONFIG_CONTRACTS" "$L2_TX_FEE_VAULT_ADDR"
require_non_empty "L2_MOAT_PROXY_ADDR in $CONFIG_CONTRACTS" "$L2_MOAT_PROXY_ADDR"

# The adapter itself does not need the doge recipient, but the rewire step does.
# Catch a missing config key here, before any chain-changing action.
if [ "$FEE_VAULT_DOGE_RECIPIENT_ADDR" = "" ] || [ "$FEE_VAULT_DOGE_RECIPIENT_ADDR" = "0x0000000000000000000000000000000000000000" ]; then
    echo "warning: FEE_VAULT_DOGE_RECIPIENT_ADDR is unset in $CONFIG"
    echo "warning: it is required by submit-fee-vault-rewire.sh before the messenger upgrade"
fi

cd "$REPO_ROOT"

echo "using REPO_ROOT = $REPO_ROOT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"

echo ""
echo "running preflight checks"
echo "Fee vault:  $L2_TX_FEE_VAULT_ADDR"
echo "Moat proxy: $L2_MOAT_PROXY_ADDR"
require_contract_code "$L2_TX_FEE_VAULT_ADDR" "L2_TX_FEE_VAULT_ADDR"
require_contract_code "$L2_MOAT_PROXY_ADDR" "L2_MOAT_PROXY_ADDR"

# Inputs:
#   BROADCAST=1             actually send the deploy tx (otherwise preflight/simulation only)
#
# This script ONLY deploys the FeeVaultMoatAdapter. It does not reconfigure the
# fee vault or the Moat — run submit-fee-vault-rewire.sh afterwards (it performs
# setFeeExempt / updateRecipient / updateMinWithdrawAmount / updateMessenger in
# the required order).
#
# Addresses are read from volume/config-contracts.toml. RPC comes from
# volume/config.toml. The deployed address is written back to
# volume/config-contracts.toml as L2_FEE_VAULT_MOAT_ADAPTER_ADDR.

# Simulate first (always).
echo ""
echo "simulating FeeVaultMoatAdapter deploy on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll \
    --rpc-url "$L2_RPC_ENDPOINT" \
    --sig "deployL2FeeVaultMoatAdapter(string,string)" "L2" "write-config" \
    --legacy

# Only broadcast if explicitly requested.
if [ "${BROADCAST:-0}" = "1" ]; then
    echo ""
    echo "broadcasting FeeVaultMoatAdapter deploy on L2"
    forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --sig "deployL2FeeVaultMoatAdapter(string,string)" "L2" "write-config" \
        --legacy \
        --broadcast
else
    echo ""
    echo "preflight/simulation only — set BROADCAST=1 to execute deploy"
fi
