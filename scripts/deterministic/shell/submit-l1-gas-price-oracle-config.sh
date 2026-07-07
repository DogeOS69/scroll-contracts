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

# Configures the owner-managed Galileo L1 data fee parameters on
# L1GasPriceOracle:
#
#   1. commitScalar  <- COMMIT_SCALAR
#   2. blobScalar    <- BLOB_SCALAR
#   3. penaltyFactor <- PENALTY_FACTOR
#
# Dynamic fee oracle values (l1BaseFee and l1BlobBaseFee) are not configured
# here; they are updated by the whitelisted fee_oracle signer.
#
# Inputs:
#   BROADCAST=1             actually send the txs (otherwise preflight only)
#   OWNER_PRIVATE_KEY=0x... L1GasPriceOracle owner key, required only when
#                           BROADCAST=1.

OWNER_PRIVATE_KEY="${OWNER_PRIVATE_KEY:-}"
CONFIG="$VOLUME_PATH/config.toml"
CONFIG_CONTRACTS="$VOLUME_PATH/config-contracts.toml"

extract_string() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$2"; }

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

require_file() {
    if [ ! -f "$1" ]; then
        echo "missing file: $1"
        exit 1
    fi
}

require_file "$CONFIG"
require_file "$CONFIG_CONTRACTS"
require_command forge

L2_RPC_ENDPOINT=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"

if [ "${BROADCAST:-0}" != "1" ]; then
    echo ""
    echo "running L1GasPriceOracle config dry run"
    forge script scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol:SubmitL1GasPriceOracleConfig \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --sig "dryRun()" \
        --legacy

    echo ""
    echo "dry run only - set BROADCAST=1 to execute the oracle config update"
    exit 0
fi

if [ "$OWNER_PRIVATE_KEY" = "" ]; then
    echo "OWNER_PRIVATE_KEY is not set for broadcast"
    exit 1
fi

echo ""
echo "broadcasting L1GasPriceOracle config on L2 via forge script"
forge script scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol:SubmitL1GasPriceOracleConfig \
    --rpc-url "$L2_RPC_ENDPOINT" \
    --legacy \
    --broadcast

echo ""
echo "post-config state"
forge script scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol:SubmitL1GasPriceOracleConfig \
    --rpc-url "$L2_RPC_ENDPOINT" \
    --sig "dryRun()" \
    --legacy
