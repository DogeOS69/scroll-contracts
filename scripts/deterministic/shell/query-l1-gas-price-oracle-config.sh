#!/bin/sh
set -eu

RPC_URL="${1:-${RPC_URL:-https://rpc.devnet.doge.xyz}}"
ORACLE_ADDR="${2:-${ORACLE_ADDR:-0x5300000000000000000000000000000000000002}}"
SAMPLE_DATA="${SAMPLE_DATA:-0x1234}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        echo "missing required command: sha256sum or shasum" >&2
        exit 1
    fi
}

print_value() {
    label="$1"
    shift
    printf '%-34s ' "$label"
    "$@"
}

call_oracle() {
    label="$1"
    sig="$2"
    print_value "$label" cast call "$ORACLE_ADDR" "$sig" --rpc-url "$RPC_URL"
}

require_command cast
require_command awk

echo "RPC_URL     = $RPC_URL"
echo "ORACLE_ADDR = $ORACLE_ADDR"
echo "SAMPLE_DATA = $SAMPLE_DATA"
echo ""

print_value "chain_id" cast chain-id --rpc-url "$RPC_URL"
print_value "block_number" cast block-number --rpc-url "$RPC_URL"
print_value "balance_wei" cast balance "$ORACLE_ADDR" --rpc-url "$RPC_URL"

CODE="$(cast code "$ORACLE_ADDR" --rpc-url "$RPC_URL")"
CODE_HEX_LEN=${#CODE}
if [ "$CODE" = "0x" ]; then
    CODE_LEN_BYTES=0
else
    CODE_LEN_BYTES=$(((CODE_HEX_LEN - 2) / 2))
fi

printf '%-34s %s\n' "code_len_bytes" "$CODE_LEN_BYTES"
printf '%-34s %s\n' "code_sha256" "$(printf '%s' "$CODE" | sha256)"
echo ""

call_oracle "owner" "owner()(address)"
WHITELIST_ADDR="$(cast call "$ORACLE_ADDR" "whitelist()(address)" --rpc-url "$RPC_URL")"
printf '%-34s %s\n' "whitelist" "$WHITELIST_ADDR"
echo ""

call_oracle "l1BaseFee" "l1BaseFee()(uint256)"
call_oracle "l1BlobBaseFee" "l1BlobBaseFee()(uint256)"
call_oracle "overhead" "overhead()(uint256)"
call_oracle "scalar" "scalar()(uint256)"
call_oracle "commitScalar" "commitScalar()(uint256)"
call_oracle "blobScalar" "blobScalar()(uint256)"
call_oracle "penaltyThreshold_deprecated" "penaltyThreshold()(uint256)"
call_oracle "penaltyFactor" "penaltyFactor()(uint256)"
echo ""

call_oracle "isCurie" "isCurie()(bool)"
call_oracle "isFeynman" "isFeynman()(bool)"
call_oracle "isGalileo" "isGalileo()(bool)"
echo ""

print_value "getL1GasUsed(sample)" cast call "$ORACLE_ADDR" "getL1GasUsed(bytes)(uint256)" "$SAMPLE_DATA" --rpc-url "$RPC_URL"
print_value "getL1Fee(sample)" cast call "$ORACLE_ADDR" "getL1Fee(bytes)(uint256)" "$SAMPLE_DATA" --rpc-url "$RPC_URL"
echo ""

if [ "$WHITELIST_ADDR" != "0x0000000000000000000000000000000000000000" ]; then
    print_value "whitelist.owner" cast call "$WHITELIST_ADDR" "owner()(address)" --rpc-url "$RPC_URL"

    if [ "${CHECK_SENDER:-}" != "" ]; then
        print_value "whitelist.isSenderAllowed" cast call "$WHITELIST_ADDR" "isSenderAllowed(address)(bool)" "$CHECK_SENDER" --rpc-url "$RPC_URL"
    fi
fi
