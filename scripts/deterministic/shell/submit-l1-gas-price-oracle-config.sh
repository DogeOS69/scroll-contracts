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

# Performs a guarded Galileo fee migration as four separately confirmed L2
# transactions:
#
#   1. l1BaseFee + l1BlobBaseFee <- fixed migration constants 1 and 1
#   2. commitScalar               <- COMMIT_SCALAR
#   3. blobScalar                 <- BLOB_SCALAR
#   4. penaltyFactor              <- PENALTY_FACTOR
#
# Each transaction is followed by a separate read-only RPC verification before
# the next transaction is allowed to broadcast. The script is idempotent and can
# be rerun after an interruption with a still-fresh candidate.
#
# Preferred candidate source:
#   FEE_ORACLE_STATUS_URL           /status URL of a dry-run fee-oracle, or
#   FEE_ORACLE_STATUS_FILE          saved JSON response from that endpoint
#
# The script derives PRODUCTION_L1_BASE_FEE, PRODUCTION_L1_BLOB_BASE_FEE, and
# PRODUCTION_FEE_OBSERVED_AT from the exact decimal-string fields and
# computed_at_ms in /status. Manual PRODUCTION_* values remain a fallback when
# neither status source is supplied.
#
# Required policy inputs (decimal integers without separators):
#   MAX_PRODUCTION_FEE_AGE_SECONDS   maximum allowed candidate age
#   MAX_PRODUCTION_L1_BASE_FEE       operator-approved hard cap
#   MAX_PRODUCTION_L1_BLOB_BASE_FEE  operator-approved hard cap
#   FEE_GUARD_COMPRESSED_BYTES       conservative signed-tx compressed size
#   MAX_L1_DATA_FEE_WEI              maximum allowed fee for that size
#
# Broadcast additionally requires:
#   BROADCAST=1
#   OWNER_PRIVATE_KEY=0x...         current L1GasPriceOracle owner
#   CONFIRM_FEE_MIGRATION=1
#   FEE_ORACLE_WRITES_STOPPED=1
#   PUBLIC_TX_INGRESS_STOPPED=1
#   FEE_ORACLE_PENDING_TXS_CLEARED=1
#
# The owner must already be allowed by L1GasPriceOracle.whitelist(). This script
# deliberately does not change whitelist membership or manage Kubernetes.

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

load_candidate_from_status() {
    if [ "${FEE_ORACLE_STATUS_URL:-}" != "" ] && [ "${FEE_ORACLE_STATUS_FILE:-}" != "" ]; then
        echo "set only one of FEE_ORACLE_STATUS_URL or FEE_ORACLE_STATUS_FILE"
        exit 1
    fi

    if [ "${FEE_ORACLE_STATUS_URL:-}" != "" ]; then
        require_command curl
        STATUS_JSON=$(curl --fail --silent --show-error "$FEE_ORACLE_STATUS_URL") || exit 1
        CANDIDATE_SOURCE="$FEE_ORACLE_STATUS_URL"
    elif [ "${FEE_ORACLE_STATUS_FILE:-}" != "" ]; then
        require_file "$FEE_ORACLE_STATUS_FILE"
        STATUS_JSON=$(jq -c . "$FEE_ORACLE_STATUS_FILE") || exit 1
        CANDIDATE_SOURCE="$FEE_ORACLE_STATUS_FILE"
    else
        return
    fi

    require_command jq

    CONTRACT_WRITE_MODE=$(printf '%s\n' "$STATUS_JSON" | jq -er '.contract_write_mode') || exit 1
    LIVE_WRITES_ENABLED=$(printf '%s\n' "$STATUS_JSON" | jq -er '.live_writes_enabled') || exit 1
    DATABASE_STATUS=$(printf '%s\n' "$STATUS_JSON" | jq -er '.database_status') || exit 1
    CANDIDATE_STATUS=$(printf '%s\n' "$STATUS_JSON" | jq -er '.latest_oracle_value.status') || exit 1

    if [ "$CONTRACT_WRITE_MODE" != "dry_run" ] || [ "$LIVE_WRITES_ENABLED" != "false" ]; then
        echo "fee-oracle candidate source must be dry_run with live writes disabled"
        exit 1
    fi
    if [ "$DATABASE_STATUS" != "ok" ]; then
        echo "fee-oracle /status reports database_status=$DATABASE_STATUS"
        exit 1
    fi
    case "$CANDIDATE_STATUS" in
        ready_to_write|capped) ;;
        *)
            echo "latest fee-oracle candidate is not writeable: status=$CANDIDATE_STATUS"
            exit 1
            ;;
    esac

    PRODUCTION_L1_BASE_FEE=$(printf '%s\n' "$STATUS_JSON" | jq -er \
        '.latest_oracle_value.oracle_l1_base_fee_dogewei_per_exec_gas | select(test("^[0-9]+$"))') || exit 1
    PRODUCTION_L1_BLOB_BASE_FEE=$(printf '%s\n' "$STATUS_JSON" | jq -er \
        '.latest_oracle_value.oracle_l1_blob_base_fee_dogewei_per_blob_gas | select(test("^[0-9]+$"))') || exit 1
    CANDIDATE_COMPUTED_AT_MS=$(printf '%s\n' "$STATUS_JSON" | jq -er \
        '.latest_oracle_value.computed_at_ms | select(type == "number" and . > 0)') || exit 1
    CANDIDATE_UUID=$(printf '%s\n' "$STATUS_JSON" | jq -er '.latest_oracle_value.value_uuid') || exit 1
    CANDIDATE_CALLDATA=$(printf '%s\n' "$STATUS_JSON" | jq -er \
        '.latest_oracle_value.calldata_hex | select(test("^0x[0-9a-fA-F]{136}$"))') || exit 1

    EXPECTED_CALLDATA=$(cast calldata \
        'setL1BaseFeeAndBlobBaseFee(uint256,uint256)' \
        "$PRODUCTION_L1_BASE_FEE" \
        "$PRODUCTION_L1_BLOB_BASE_FEE") || exit 1
    if [ "$(printf '%s' "$CANDIDATE_CALLDATA" | tr '[:upper:]' '[:lower:]')" != "$EXPECTED_CALLDATA" ]; then
        echo "fee-oracle /status calldata does not encode the reported DOGE-denominated candidate"
        exit 1
    fi

    PRODUCTION_FEE_OBSERVED_AT=$((CANDIDATE_COMPUTED_AT_MS / 1000))
    export PRODUCTION_L1_BASE_FEE
    export PRODUCTION_L1_BLOB_BASE_FEE
    export PRODUCTION_FEE_OBSERVED_AT

    echo "derived candidate source = $CANDIDATE_SOURCE"
    echo "derived candidate uuid = $CANDIDATE_UUID"
    echo "derived candidate status = $CANDIDATE_STATUS"
    echo "derived candidate computed_at_ms = $CANDIDATE_COMPUTED_AT_MS"
    echo "derived candidate calldata = $CANDIDATE_CALLDATA"
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
require_command jq
require_command cast

L2_RPC_ENDPOINT=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")

require_non_empty "EXTERNAL_RPC_URI_L2 in $CONFIG" "$L2_RPC_ENDPOINT"
load_candidate_from_status
require_non_empty "PRODUCTION_L1_BASE_FEE" "${PRODUCTION_L1_BASE_FEE:-}"
require_non_empty "PRODUCTION_L1_BLOB_BASE_FEE" "${PRODUCTION_L1_BLOB_BASE_FEE:-}"
require_non_empty "PRODUCTION_FEE_OBSERVED_AT" "${PRODUCTION_FEE_OBSERVED_AT:-}"
require_non_empty "MAX_PRODUCTION_FEE_AGE_SECONDS" "${MAX_PRODUCTION_FEE_AGE_SECONDS:-}"
require_non_empty "MAX_PRODUCTION_L1_BASE_FEE" "${MAX_PRODUCTION_L1_BASE_FEE:-}"
require_non_empty "MAX_PRODUCTION_L1_BLOB_BASE_FEE" "${MAX_PRODUCTION_L1_BLOB_BASE_FEE:-}"
require_non_empty "FEE_GUARD_COMPRESSED_BYTES" "${FEE_GUARD_COMPRESSED_BYTES:-}"
require_non_empty "MAX_L1_DATA_FEE_WEI" "${MAX_L1_DATA_FEE_WEI:-}"

cd "$REPO_ROOT"

echo ""
echo "using REPO_ROOT = $REPO_ROOT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"
echo ""
echo "running guarded L1GasPriceOracle migration preflight"
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
echo "fee migration completed"
echo "next: submit an internal canary transaction before allowing the new fee-oracle signer"
