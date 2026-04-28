#!/bin/sh
# Verifies that the canonical preinstall addresses on the target RPC have
# the expected runtime codehash (baked into this script).
#
# Two typical uses:
#   - Right after running deploy.sh against the L2, verify the deploy landed.
#   - With Ethereum mainnet's RPC, verify the baked codehash constants are
#     themselves authentic (anchored against the real mainnet contracts).
#
# Setup:
#   source .env
#   bash scripts/preinstalls/shell/verify.sh
#
# Defaults RPC to L2_RPC_ENDPOINT (the standard scroll-contracts var). To
# anchor against Ethereum mainnet instead:
#   L2_RPC_ENDPOINT=https://ethereum-rpc.publicnode.com bash scripts/preinstalls/shell/verify.sh
#
# Multicall3 and CreateX have no chainId-dependent immutables, so the same
# codehash applies on every chain.
set -e

if [ "${L2_RPC_ENDPOINT}" = "" ]; then
    echo "L2_RPC_ENDPOINT is not set"
    exit 1
fi

PREINSTALLS="\
Multicall3|0xcA11bde05977b3631167028862bE2a173976CA11|0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891
CreateX|0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed|0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f"

echo "RPC: $L2_RPC_ENDPOINT"
echo ""

fail=0
echo "$PREINSTALLS" | while IFS='|' read -r name address codehash; do
    code=$(cast code "$address" --rpc-url "$L2_RPC_ENDPOINT")
    if [ -z "$code" ] || [ "$code" = "0x" ]; then
        printf "  [missing] %-12s %s\n" "$name" "$address"
        exit 1
    fi
    actual=$(cast keccak "$code")
    if [ "$actual" = "$codehash" ]; then
        printf "  [ok]      %-12s %s\n" "$name" "$address"
    else
        printf "  [diff]    %-12s %s\n" "$name" "$address"
        printf "            expected: %s\n" "$codehash"
        printf "            actual:   %s\n" "$actual"
        exit 1
    fi
done
