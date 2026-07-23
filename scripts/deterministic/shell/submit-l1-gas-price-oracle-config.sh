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

# Applies the fixed migration fee pair and three static Galileo fee parameters
# as separately confirmed L2
# transactions:
#
#   1. l1BaseFee + l1BlobBaseFee <- fixed constants 1 and 1
#   2. commitScalar               <- COMMIT_SCALAR
#   3. blobScalar                 <- BLOB_SCALAR
#   4. penaltyFactor              <- PENALTY_FACTOR
#
# Each transaction is followed by a separate read-only RPC verification before
# the next transaction is allowed to broadcast. The script is idempotent and can
# be rerun after an interruption. The external fee-oracle signer replaces the
# temporary 1/1 dynamic pair after handoff.
#
# Broadcast additionally requires:
#   BROADCAST=1
#   OWNER_PRIVATE_KEY=0x...         current L1GasPriceOracle owner
#   CONFIRM_FEE_MIGRATION=1
#   FEE_ORACLE_WRITES_STOPPED=1
#   PUBLIC_TX_INGRESS_STOPPED=1
#   FEE_ORACLE_PENDING_TXS_CLEARED=1
# The dynamic setter requires the owner to be temporarily whitelisted. The
# wrapper manages that permission; this script does not manage Kubernetes.

export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"

OWNER_PRIVATE_KEY="${OWNER_PRIVATE_KEY:-}"
CONFIG="$VOLUME_PATH/config.toml"
CONFIG_CONTRACTS="$VOLUME_PATH/config-contracts.toml"
SCRIPT_TARGET="scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol:SubmitL1GasPriceOracleConfig"

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

require_ack() {
    name="$1"
    value="$2"
    if [ "$value" != "1" ]; then
        echo "$name must be set to 1 for broadcast"
        exit 1
    fi
}

run_readonly() {
    signature="$1"
    forge script "$SCRIPT_TARGET" \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --sig "$signature" \
        --legacy
}

run_broadcast() {
    signature="$1"
    forge script "$SCRIPT_TARGET" \
        --rpc-url "$L2_RPC_ENDPOINT" \
        --sig "$signature" \
        --legacy \
        --broadcast
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
echo ""
echo "running L1GasPriceOracle fixed-pair/static-parameter migration preflight"
run_readonly "dryRun()"

if [ "${BROADCAST:-0}" != "1" ]; then
    echo ""
    echo "dry run only - no transaction was sent"
    echo "set BROADCAST=1 and all maintenance acknowledgements to execute"
    exit 0
fi

if [ "$OWNER_PRIVATE_KEY" = "" ]; then
    echo "OWNER_PRIVATE_KEY is not set for broadcast"
    exit 1
fi

require_ack CONFIRM_FEE_MIGRATION "${CONFIRM_FEE_MIGRATION:-}"
require_ack FEE_ORACLE_WRITES_STOPPED "${FEE_ORACLE_WRITES_STOPPED:-}"
require_ack PUBLIC_TX_INGRESS_STOPPED "${PUBLIC_TX_INGRESS_STOPPED:-}"
require_ack FEE_ORACLE_PENDING_TXS_CLEARED "${FEE_ORACLE_PENDING_TXS_CLEARED:-}"

echo ""
echo "step 1/4: broadcasting fixed 1/1 migration dynamic fee pair"
run_broadcast "setMigrationDynamic()"
run_readonly "verifyMigrationDynamic()"
echo "step 1/4 verified on chain"

echo ""
echo "step 2/4: broadcasting commit scalar"
run_broadcast "setCommitScalar()"
run_readonly "verifyCommitScalar()"
echo "step 2/4 verified on chain"

echo ""
echo "step 3/4: broadcasting blob scalar"
run_broadcast "setBlobScalar()"
run_readonly "verifyBlobScalar()"
echo "step 3/4 verified on chain"

echo ""
echo "step 4/4: broadcasting penalty factor"
run_broadcast "setPenaltyFactor()"
run_readonly "verifyFinalState()"
echo "step 4/4 verified on chain"

echo ""
echo "final fee tuple"
run_readonly "dryRun()"

echo ""
echo "fixed 1/1 migration pair and static fee parameters updated"
echo "next: submit an internal canary transaction before allowing the fee-oracle signer"
