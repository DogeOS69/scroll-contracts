#!/bin/sh
# Enable timestamped execution trace to show progress with time and line numbers
export PS4='$(date "+%Y-%m-%dT%H:%M:%S%z") ${0##*/}:${LINENO}: '
echo "=== SCRIPT START ==="
export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"
set -ex

CONFIG_FILE="./volume/config.toml"

# Set default values for environment variables if they are not set
L1_RPC_ENDPOINT="${L1_RPC_ENDPOINT}"
L2_RPC_ENDPOINT="${L2_RPC_ENDPOINT}"
# Using a smaller batch size as a compromise between the slow but reliable --slow flag and the fast but potentially unreliable default.
BATCH_SIZE="7"

echo "using L1_RPC_ENDPOINT = $L1_RPC_ENDPOINT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"
echo "Environment variables:"
echo "FOUNDRY_EVM_VERSION: $FOUNDRY_EVM_VERSION"
echo "FOUNDRY_BYTECODE_HASH: $FOUNDRY_BYTECODE_HASH"
echo "BATCH_SIZE: $BATCH_SIZE"

# simulate L1
# echo ""
# echo "simulating on L1"
# forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --sig "run(string,string)" "L1" "verify-config" 

# # deploy L1
# echo ""
# echo "deploying on L1"
# forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --batch-size "${BATCH_SIZE}" --sig "run(string,string)" "L1" "verify-config" --broadcast --json 


# simulate L2
echo ""
echo "simulating on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT" --sig "run(string,string)" "L2" "verify-config" --legacy


# deploy L2
echo ""
echo "deploying on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT"  --batch-size "$BATCH_SIZE" --sig "run(string,string)" "L2" "verify-config" --broadcast --legacy --json

echo "=== SCRIPT END ==="
