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

# Adds an account to the L2 Whitelist used by L1GasPriceOracle.
#
# Inputs:
#   WHITELIST_ACCOUNT=0x... account to allow. Can also be passed as $1.
#   BROADCAST=1             actually send the tx (otherwise preflight only).
#   OWNER_PRIVATE_KEY=0x... whitelist owner key, required only when BROADCAST=1.
#
# Optional overrides:
#   RPC_URL=...             defaults to EXTERNAL_RPC_URI_L2 from volume/config.toml.
#   WHITELIST_ADDR=0x...    defaults to L2_WHITELIST_ADDR from
#                           volume/config-contracts.toml.

CONFIG="$VOLUME_PATH/config.toml"
CONFIG_CONTRACTS="$VOLUME_PATH/config-contracts.toml"
OWNER_PRIVATE_KEY="${OWNER_PRIVATE_KEY:-}"
WHITELIST_ACCOUNT="${1:-${WHITELIST_ACCOUNT:-}}"

extract_string() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$2"; }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1"
        exit 1
    fi
}

require_file() {
    if [ ! -f "$1" ]; then
        echo "missing file: $1"
        exit 1
    fi
}

require_non_empty() {
    if [ "$2" = "" ]; then
        echo "$1 is not set"
        exit 1
    fi
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

require_contract_code() {
    code=$(cast code "$1" --rpc-url "$RPC_URL") || exit 1
    if [ "$code" = "0x" ]; then
        echo "$2 has no deployed code at $1"
        exit 1
    fi
}

require_file "$CONFIG"
require_file "$CONFIG_CONTRACTS"
require_command cast

RPC_URL="${RPC_URL:-$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")}"
WHITELIST_ADDR="${WHITELIST_ADDR:-$(extract_string L2_WHITELIST_ADDR "$CONFIG_CONTRACTS")}"

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG or RPC_URL" "$RPC_URL"
require_non_empty "L2_WHITELIST_ADDR in $CONFIG_CONTRACTS or WHITELIST_ADDR" "$WHITELIST_ADDR"
require_non_empty "WHITELIST_ACCOUNT or first argument" "$WHITELIST_ACCOUNT"

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "using RPC_URL = $RPC_URL"
echo "using WHITELIST_ADDR = $WHITELIST_ADDR"
echo "using WHITELIST_ACCOUNT = $WHITELIST_ACCOUNT"

echo ""
echo "running preflight checks"
require_contract_code "$WHITELIST_ADDR" "WHITELIST_ADDR"

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
OWNER=$(cast call "$WHITELIST_ADDR" "owner()(address)" --rpc-url "$RPC_URL") || exit 1
IS_ALLOWED=$(cast call "$WHITELIST_ADDR" "isSenderAllowed(address)(bool)" "$WHITELIST_ACCOUNT" --rpc-url "$RPC_URL") || exit 1

echo "chain id:            $CHAIN_ID"
echo "whitelist owner:     $OWNER"
echo "is currently allowed: $IS_ALLOWED"

if [ "$IS_ALLOWED" = "true" ]; then
    echo ""
    echo "account is already whitelisted"
    exit 0
fi

if [ "${BROADCAST:-0}" != "1" ]; then
    echo ""
    echo "preflight only - set BROADCAST=1 to add the account"
    exit 0
fi

if [ "$OWNER_PRIVATE_KEY" = "" ]; then
    echo "OWNER_PRIVATE_KEY is not set for broadcast"
    exit 1
fi

SIGNER=$(cast wallet address --private-key "$OWNER_PRIVATE_KEY") || exit 1
echo "signer:              $SIGNER"

if [ "$(lower "$SIGNER")" != "$(lower "$OWNER")" ]; then
    echo "OWNER_PRIVATE_KEY controls $SIGNER, but whitelist owner is $OWNER"
    exit 1
fi

echo ""
echo "broadcasting whitelist update"
cast send "$WHITELIST_ADDR" \
    "updateWhitelistStatus(address[],bool)" \
    "[$WHITELIST_ACCOUNT]" \
    true \
    --rpc-url "$RPC_URL" \
    --private-key "$OWNER_PRIVATE_KEY"

echo ""
echo "post-update state"
POST_ALLOWED=$(cast call "$WHITELIST_ADDR" "isSenderAllowed(address)(bool)" "$WHITELIST_ACCOUNT" --rpc-url "$RPC_URL") || exit 1
echo "is currently allowed: $POST_ALLOWED"

if [ "$POST_ALLOWED" != "true" ]; then
    echo "post-update check failed: account is not whitelisted"
    exit 1
fi
