#!/bin/sh
# Deploy race-critical EVM preinstalls (Multicall3, CreateX) to their canonical
# addresses on the L2 by replaying publicly published presigned legacy
# unprotected transactions. Idempotent.
#
# Setup:
#   cp .env.example .env  &&  edit  &&  source .env
#   bash scripts/preinstalls/shell/deploy.sh
#
# Required env vars (already in .env.example for the standard scroll-contracts
# deploy flow): L2_RPC_ENDPOINT, L2_DEPLOYER_PRIVATE_KEY.
#
# The L2 RPC must accept legacy unprotected (pre-EIP-155) transactions. On
# scroll-geth that means starting the node with --rpc.allow-unprotected-txs
# for the deploy window. The standard scroll-contracts deploys use --legacy
# (EIP-155-protected) so they don't require the flag — these presigned txs do.
#
# Why bash + cast and not forge: these are presigned txs from third parties
# (mds1, pcaversaccio). Forge's vm.broadcastRawTransaction simulates locally
# but does not emit to the RPC in forge 1.5.1. cast publish is the correct
# tool for "publish this exact tx as-is".
set -e

if [ "${L2_RPC_ENDPOINT}" = "" ]; then
    echo "L2_RPC_ENDPOINT is not set"
    exit 1
fi
if [ "${L2_DEPLOYER_PRIVATE_KEY}" = "" ]; then
    echo "L2_DEPLOYER_PRIVATE_KEY is not set"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Each entry: name | address | codehash | deployer | fundingWei | binFile
PREINSTALLS="\
Multicall3|0xcA11bde05977b3631167028862bE2a173976CA11|0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891|0x05f32B3cC3888453ff71B01135B34FF8e41263F2|100000000000000000|data/multicall3.bin
CreateX|0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed|0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f|0xeD456e05caab11d66c4c797dd6c1d6f9a7f352b5|300000000000000000|data/createx.bin"

# Compares two non-negative decimal-integer strings without int64 overflow.
str_lt() {
    a="$1"; b="$2"
    if [ ${#a} -ne ${#b} ]; then [ ${#a} -lt ${#b} ]; else [ "$a" \< "$b" ]; fi
}

OPERATOR=$(cast wallet address --private-key "$L2_DEPLOYER_PRIVATE_KEY")
echo ""
echo "=== dogeos-preinstalls ==="
echo "  RPC:      $L2_RPC_ENDPOINT"
echo "  Operator: $OPERATOR"
echo "  Balance:  $(cast balance "$OPERATOR" --rpc-url "$L2_RPC_ENDPOINT") wei"
echo "  ChainId:  $(cast chain-id --rpc-url "$L2_RPC_ENDPOINT")"

# Pre-flight sanity: each canonical address must derive from (deployer, nonce=0).
echo ""
echo "=== pre-flight sanity ==="
echo "$PREINSTALLS" | while IFS='|' read -r name address codehash deployer funding_wei binfile; do
    derived=$(cast compute-address --nonce 0 "$deployer" \
              | awk '/Computed Address:/ {print $3}')
    if [ "$(echo "$derived" | tr A-F a-f)" != "$(echo "$address" | tr A-F a-f)" ]; then
        echo "  [error] $name: $address does not derive from $deployer + nonce=0"
        exit 1
    fi
    echo "  $name: $address ← $deployer + nonce=0"
done

deployed=0
skipped=0
failed=0

echo "$PREINSTALLS" | while IFS='|' read -r name address codehash deployer funding_wei binfile; do
    echo ""
    echo "=== $name ==="
    echo "  target:   $address"

    code=$(cast code "$address" --rpc-url "$L2_RPC_ENDPOINT")
    if [ -n "$code" ] && [ "$code" != "0x" ]; then
        actual=$(cast keccak "$code")
        if [ "$actual" = "$codehash" ]; then
            echo "  [skip]    already deployed with matching codehash"
            continue
        else
            echo "  [error]   address has code but codehash mismatches" >&2
            echo "            expected: $codehash" >&2
            echo "            actual:   $actual" >&2
            exit 1
        fi
    fi

    current_bal=$(cast balance "$deployer" --rpc-url "$L2_RPC_ENDPOINT")
    if str_lt "$current_bal" "$funding_wei"; then
        top_up=$((funding_wei - current_bal))
        echo "  funding:  $deployer with $top_up wei"
        cast send "$deployer" --value "$top_up" \
            --rpc-url "$L2_RPC_ENDPOINT" --private-key "$L2_DEPLOYER_PRIVATE_KEY" >/dev/null
    else
        echo "  funded:   $deployer already has $current_bal wei"
    fi

    raw_tx="0x$(xxd -p -c 0 "$SCRIPT_DIR/$binfile")"
    echo "  publish:  raw tx ($((${#raw_tx} - 2)) hex chars)"
    cast publish "$raw_tx" --rpc-url "$L2_RPC_ENDPOINT" >/dev/null

    code=$(cast code "$address" --rpc-url "$L2_RPC_ENDPOINT")
    if [ -z "$code" ] || [ "$code" = "0x" ]; then
        echo "  [error]   no code at $address after deploy" >&2
        exit 1
    fi
    actual=$(cast keccak "$code")
    if [ "$actual" != "$codehash" ]; then
        echo "  [error]   post-deploy codehash mismatch" >&2
        echo "            expected: $codehash" >&2
        echo "            actual:   $actual" >&2
        exit 1
    fi

    echo "  [ok]      $name deployed at $address"
done

echo ""
echo "=== done ==="
