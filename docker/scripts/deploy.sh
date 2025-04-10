#!/bin/sh
echo "=== SCRIPT START ==="
export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"
set -e

echo "Environment variables:"
echo "FOUNDRY_EVM_VERSION: $FOUNDRY_EVM_VERSION"
echo "FOUNDRY_BYTECODE_HASH: $FOUNDRY_BYTECODE_HASH"
echo "BATCH_SIZE: $BATCH_SIZE"

if [ "${L1_RPC_ENDPOINT}" = "" ]; then
    echo "L1_RPC_ENDPOINT is not set"
    L1_RPC_ENDPOINT="http://host.docker.internal:8543"
fi

if [ "$L2_RPC_ENDPOINT" = "" ]; then
    echo "L2_RPC_ENDPOINT is not set"
    L2_RPC_ENDPOINT="http://host.docker.internal:8545"
fi

if [ "${BATCH_SIZE}" = "" ]; then
    BATCH_SIZE="100"
fi

echo "using L1_RPC_ENDPOINT = $L1_RPC_ENDPOINT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"

# simulate L1
echo ""
echo "simulating on L1"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --sig "run(string,string)" "L1" "verify-config" || exit 1

# simulate L2
echo ""
echo "simulating on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT" --sig "run(string,string)" "L2" "verify-config" --legacy || exit 1

# deploy L1
echo ""
echo "deploying on L1"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --batch-size "$BATCH_SIZE" --sig "run(string,string)" "L1" "verify-config" --broadcast || exit 1

# deploy L2
echo ""
echo "deploying on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT"  --batch-size "$BATCH_SIZE" --sig "run(string,string)" "L2" "verify-config" --broadcast --legacy || exit 1

# log broadcast files

echo "=== START BROADCAST FILES ==="
echo "Current directory: $(pwd)"
echo "Broadcast files location: broadcast/DeployScroll.s.sol/*/*"
echo "Found files:"
ls -la broadcast/DeployScroll.s.sol/*/* || echo "No files found"
echo "Broadcast files content:"

for file in broadcast/DeployScroll.s.sol/*/*; do
  if [ -f "$file" ]; then
    echo "$file:"
    cat "$file"
    echo ""
  fi
done
echo "=== END BROADCAST FILES ==="