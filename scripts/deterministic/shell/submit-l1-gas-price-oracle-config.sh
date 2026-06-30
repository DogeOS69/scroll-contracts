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
extract_uint() {
    sed -n "s/^$1 *= *\"\\{0,1\\}\\([0-9_][0-9_]*\\)\"\\{0,1\\}.*/\\1/p" "$2" | tr -d '_'
}

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

L2_RPC_ENDPOINT=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")
L1_GAS_PRICE_ORACLE_ADDR=$(extract_string L1_GAS_PRICE_ORACLE_ADDR "$CONFIG_CONTRACTS")
COMMIT_SCALAR=$(extract_uint COMMIT_SCALAR "$CONFIG")
BLOB_SCALAR=$(extract_uint BLOB_SCALAR "$CONFIG")
PENALTY_FACTOR=$(extract_uint PENALTY_FACTOR "$CONFIG")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
require_non_empty "L1_GAS_PRICE_ORACLE_ADDR in $CONFIG_CONTRACTS" "$L1_GAS_PRICE_ORACLE_ADDR"
require_non_empty "COMMIT_SCALAR in $CONFIG" "$COMMIT_SCALAR"
require_non_empty "BLOB_SCALAR in $CONFIG" "$BLOB_SCALAR"
require_non_empty "PENALTY_FACTOR in $CONFIG" "$PENALTY_FACTOR"

if [ "$COMMIT_SCALAR" = "0" ]; then
    echo "COMMIT_SCALAR must not be zero"
    exit 1
fi
if [ "$BLOB_SCALAR" = "0" ]; then
    echo "BLOB_SCALAR must not be zero"
    exit 1
fi
if [ "$PENALTY_FACTOR" = "0" ]; then
    echo "PENALTY_FACTOR must not be zero"
    exit 1
fi

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "running preflight checks"
require_contract_code "$L1_GAS_PRICE_ORACLE_ADDR" "L1_GAS_PRICE_ORACLE_ADDR"

echo "RPC:       $L2_RPC_ENDPOINT"
echo "Oracle:    $L1_GAS_PRICE_ORACLE_ADDR"
ORACLE_OWNER=$(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'owner()(address)' --rpc-url "$L2_RPC_ENDPOINT") || exit 1
echo "Owner:     $ORACLE_OWNER"

echo ""
echo "current state"
echo "commitScalar:  $(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'commitScalar()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
echo "blobScalar:    $(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'blobScalar()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
echo "penaltyFactor: $(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'penaltyFactor()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
echo ""
echo "target state from $CONFIG"
echo "commitScalar:  $COMMIT_SCALAR"
echo "blobScalar:    $BLOB_SCALAR"
echo "penaltyFactor: $PENALTY_FACTOR"

if [ "${BROADCAST:-0}" != "1" ]; then
    echo ""
    echo "preflight only - set BROADCAST=1 to execute the oracle config update"
    exit 0
fi

if [ "$OWNER_PRIVATE_KEY" = "" ]; then
    echo "OWNER_PRIVATE_KEY is not set for broadcast"
    exit 1
fi
require_command forge

echo ""
echo "broadcasting L1GasPriceOracle config on L2 via forge script"
forge script scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol:SubmitL1GasPriceOracleConfig \
    --rpc-url "$L2_RPC_ENDPOINT" \
    --legacy \
    --broadcast

echo ""
echo "post-config state"
echo "commitScalar:  $(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'commitScalar()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
echo "blobScalar:    $(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'blobScalar()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
echo "penaltyFactor: $(cast call "$L1_GAS_PRICE_ORACLE_ADDR" 'penaltyFactor()(uint256)' --rpc-url "$L2_RPC_ENDPOINT")"
