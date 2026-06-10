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

# Rewires the fee vault through the FeeVaultMoatAdapter (and thus the Moat), in
# the required order:
#
#   1. Moat.setFeeExempt(adapter, true)        — protocol pays no withdrawal fee
#   2. L2TxFeeVault.updateRecipient(...)       — Dogecoin P2PKH hash160 recipient
#   3. L2TxFeeVault.updateMinWithdrawAmount()  — >= moat min + 1 satoshi headroom
#   4. L2TxFeeVault.updateMessenger(adapter)   — routes withdrawals through the Moat
#
# Steps 1-3 MUST land before step 4, and all four before the messenger proxy
# upgrade (which removes the vault's direct send permission). Each step is
# skipped when the on-chain value is already correct, so reruns are safe.
#
# Inputs:
#   BROADCAST=1             actually send the txs (otherwise preflight only)
#   OWNER_PRIVATE_KEY=0x... Moat + fee vault owner key — required only when
#                           BROADCAST=1. Both contracts are expected to share
#                           one owner; the preflight prints both owners.

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
L2_TX_FEE_VAULT_ADDR=$(extract L2_TX_FEE_VAULT_ADDR "$CONFIG_CONTRACTS")
L2_MOAT_PROXY_ADDR=$(extract L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
L2_FEE_VAULT_MOAT_ADAPTER_ADDR=$(extract L2_FEE_VAULT_MOAT_ADAPTER_ADDR "$CONFIG_CONTRACTS")
FEE_VAULT_DOGE_RECIPIENT_ADDR=$(extract FEE_VAULT_DOGE_RECIPIENT_ADDR "$CONFIG")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
require_non_empty "L2_TX_FEE_VAULT_ADDR in $CONFIG_CONTRACTS" "$L2_TX_FEE_VAULT_ADDR"
require_non_empty "L2_MOAT_PROXY_ADDR in $CONFIG_CONTRACTS" "$L2_MOAT_PROXY_ADDR"
require_non_empty "L2_FEE_VAULT_MOAT_ADAPTER_ADDR in $CONFIG_CONTRACTS (run deploy-fee-vault-moat-adapter.sh first)" "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR"
require_non_empty "FEE_VAULT_DOGE_RECIPIENT_ADDR in $CONFIG" "$FEE_VAULT_DOGE_RECIPIENT_ADDR"

if [ "$(lower "$FEE_VAULT_DOGE_RECIPIENT_ADDR")" = "0x0000000000000000000000000000000000000000" ]; then
    echo "FEE_VAULT_DOGE_RECIPIENT_ADDR must not be the zero address"
    exit 1
fi

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "running preflight checks"
require_contract_code "$L2_TX_FEE_VAULT_ADDR" "L2_TX_FEE_VAULT_ADDR"
require_contract_code "$L2_MOAT_PROXY_ADDR" "L2_MOAT_PROXY_ADDR"
require_contract_code "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR" "L2_FEE_VAULT_MOAT_ADAPTER_ADDR"

echo "RPC:            $L2_RPC_ENDPOINT"
echo "Fee vault:      $L2_TX_FEE_VAULT_ADDR"
echo "Moat proxy:     $L2_MOAT_PROXY_ADDR"
echo "Adapter:        $L2_FEE_VAULT_MOAT_ADAPTER_ADDR"
echo "Doge recipient: $FEE_VAULT_DOGE_RECIPIENT_ADDR"

# Confirm the adapter is wired to the expected vault + moat.
ADAPTER_VAULT=$(cast call "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR" 'FEE_VAULT()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
ADAPTER_MOAT=$(cast call "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR" 'MOAT()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
if [ "$(lower "$ADAPTER_VAULT")" != "$(lower "$L2_TX_FEE_VAULT_ADDR")" ]; then
    echo "adapter FEE_VAULT ($ADAPTER_VAULT) does not match L2_TX_FEE_VAULT_ADDR"
    exit 1
fi
if [ "$(lower "$ADAPTER_MOAT")" != "$(lower "$L2_MOAT_PROXY_ADDR")" ]; then
    echo "adapter MOAT ($ADAPTER_MOAT) does not match L2_MOAT_PROXY_ADDR"
    exit 1
fi

# The new Moat implementation (with SATOSHI_TO_WEI / setFeeExempt) must already
# be active on the proxy — upgrade the Moat before running this script.
if ! SATOSHI=$(cast call "$L2_MOAT_PROXY_ADDR" 'SATOSHI_TO_WEI()(uint256)' --rpc-url "$L2_RPC_ENDPOINT" 2>/dev/null); then
    echo "Moat proxy does not expose SATOSHI_TO_WEI() — upgrade the Moat implementation first"
    exit 1
fi
SATOSHI=$(printf '%s' "$SATOSHI" | awk '{print $1}')

MOAT_OWNER=$(cast call "$L2_MOAT_PROXY_ADDR" 'owner()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
VAULT_OWNER=$(cast call "$L2_TX_FEE_VAULT_ADDR" 'owner()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "Moat owner:     $MOAT_OWNER"
echo "Vault owner:    $VAULT_OWNER"
if [ "$(lower "$MOAT_OWNER")" != "$(lower "$VAULT_OWNER")" ]; then
    echo "warning: Moat and fee vault owners differ — OWNER_PRIVATE_KEY must control both for a single run"
fi

IS_EXEMPT=$(cast call "$L2_MOAT_PROXY_ADDR" 'feeExemptCallers(address)(bool)' "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR" --rpc-url "$L2_RPC_ENDPOINT") || exit 1
RECIPIENT_BEFORE=$(cast call "$L2_TX_FEE_VAULT_ADDR" 'recipient()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
MIN_BEFORE=$(cast call "$L2_TX_FEE_VAULT_ADDR" 'minWithdrawAmount()(uint256)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
MIN_BEFORE=$(printf '%s' "$MIN_BEFORE" | awk '{print $1}')
MESSENGER_BEFORE=$(cast call "$L2_TX_FEE_VAULT_ADDR" 'messenger()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
MOAT_MIN=$(cast call "$L2_MOAT_PROXY_ADDR" 'minWithdrawalAmount()(uint256)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
MOAT_MIN=$(printf '%s' "$MOAT_MIN" | awk '{print $1}')
REQUIRED_MIN=$((MOAT_MIN + SATOSHI))

echo ""
echo "current state"
echo "adapter fee-exempt:    $IS_EXEMPT"
echo "vault recipient:       $RECIPIENT_BEFORE"
echo "vault minWithdraw:     $MIN_BEFORE"
echo "vault messenger:       $MESSENGER_BEFORE"
echo "required vault min:    $REQUIRED_MIN (moat min $MOAT_MIN + 1 satoshi $SATOSHI)"

if [ "${BROADCAST:-0}" != "1" ]; then
    echo ""
    echo "preflight only — set BROADCAST=1 to execute the rewire"
    exit 0
fi

if [ "$OWNER_PRIVATE_KEY" = "" ]; then
    echo "OWNER_PRIVATE_KEY is not set for broadcast"
    exit 1
fi

send() {
    cast send "$@" --rpc-url "$L2_RPC_ENDPOINT" --private-key "$OWNER_PRIVATE_KEY" --legacy
}

echo ""
echo "step 1/4: Moat.setFeeExempt(adapter, true)"
if [ "$IS_EXEMPT" = "true" ]; then
    echo "already exempt — skipping"
else
    send "$L2_MOAT_PROXY_ADDR" 'setFeeExempt(address,bool)' "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR" true
fi

echo ""
echo "step 2/4: L2TxFeeVault.updateRecipient($FEE_VAULT_DOGE_RECIPIENT_ADDR)"
if [ "$(lower "$RECIPIENT_BEFORE")" = "$(lower "$FEE_VAULT_DOGE_RECIPIENT_ADDR")" ]; then
    echo "already set — skipping"
else
    send "$L2_TX_FEE_VAULT_ADDR" 'updateRecipient(address)' "$FEE_VAULT_DOGE_RECIPIENT_ADDR"
fi

echo ""
echo "step 3/4: L2TxFeeVault.updateMinWithdrawAmount($REQUIRED_MIN)"
if [ "$MIN_BEFORE" -ge "$REQUIRED_MIN" ]; then
    echo "already >= required — skipping"
else
    send "$L2_TX_FEE_VAULT_ADDR" 'updateMinWithdrawAmount(uint256)' "$REQUIRED_MIN"
fi

echo ""
echo "step 4/4: L2TxFeeVault.updateMessenger(adapter)"
if [ "$(lower "$MESSENGER_BEFORE")" = "$(lower "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR")" ]; then
    echo "already set — skipping"
else
    send "$L2_TX_FEE_VAULT_ADDR" 'updateMessenger(address)' "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR"
fi

echo ""
echo "post-rewire state"
echo "adapter fee-exempt: $(cast call "$L2_MOAT_PROXY_ADDR" 'feeExemptCallers(address)(bool)' "$L2_FEE_VAULT_MOAT_ADAPTER_ADDR" --rpc-url "$L2_RPC_ENDPOINT")"
echo "vault recipient:    $(cast call "$L2_TX_FEE_VAULT_ADDR" 'recipient()(address)' --rpc-url "$L2_RPC_ENDPOINT")"
echo "vault minWithdraw:  $(cast call "$L2_TX_FEE_VAULT_ADDR" 'minWithdrawAmount()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
echo "vault messenger:    $(cast call "$L2_TX_FEE_VAULT_ADDR" 'messenger()(address)' --rpc-url "$L2_RPC_ENDPOINT")"
