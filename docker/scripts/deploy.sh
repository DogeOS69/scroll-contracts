#!/bin/sh
echo "=== SCRIPT START ==="
export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"
set -ex

# --- Configuration Loading ---
# This section mimics the logic in Configuration.sol:
# 1. Check for the necessary private key environment variables.
# 2. If not found, fall back to reading from the config file for local development.

CONFIG_FILE="./volume/config.toml"

# Helper function to load a key from env or file and export it.
load_pk() {
  local key_name="$1"
  # Indirectly get the value of the variable named by key_name
  eval "local key_value=\$$key_name"

  if [ -z "$key_value" ] && [ -f "$CONFIG_FILE" ]; then
    # This simple parser assumes the format: KEY = "0x..."
    local pk_from_file
    pk_from_file=$(grep "^${key_name} " "$CONFIG_FILE" | head -n 1 | cut -d '"' -f 2)
    if [ -n "$pk_from_file" ]; then
      export "${key_name}=${pk_from_file}"
      echo "INFO: Loaded ${key_name} from $CONFIG_FILE."
    fi
  fi
}

# Load all private keys required by the Solidity script.
load_pk "DEPLOYER_PRIVATE_KEY"

# Final check for the main deployer key, which is essential for broadcasting.
if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
  echo "Error: DEPLOYER_PRIVATE_KEY is not set and could not be found in $CONFIG_FILE."
  echo "Please set it as an environment variable or in the config file."
  exit 1
fi

# Set default values for environment variables if they are not set
L1_RPC_ENDPOINT="${L1_RPC_ENDPOINT}"
L2_RPC_ENDPOINT="${L2_RPC_ENDPOINT}"
# Using a smaller batch size as a compromise between the slow but reliable --slow flag and the fast but potentially unreliable default.
BATCH_SIZE="${BATCH_SIZE:-10}"

echo "using L1_RPC_ENDPOINT = $L1_RPC_ENDPOINT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"
echo "Environment variables:"
echo "FOUNDRY_EVM_VERSION: $FOUNDRY_EVM_VERSION"
echo "FOUNDRY_BYTECODE_HASH: $FOUNDRY_BYTECODE_HASH"
echo "BATCH_SIZE: $BATCH_SIZE"

# simulate L1
echo ""
echo "simulating on L1"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --sig "run(string,string)" "L1" "verify-config" -vvv

# deploy L1
echo ""
echo "deploying on L1"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --batch-size "$BATCH_SIZE" --sig "run(string,string)" "L1" "verify-config" --broadcast  -vvv --private-key "$DEPLOYER_PRIVATE_KEY"


# simulate L2
echo ""
echo "simulating on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT" --sig "run(string,string)" "L2" "verify-config" --legacy -vvv


# deploy L2
echo ""
echo "deploying on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT"  --batch-size "$BATCH_SIZE" --sig "run(string,string)" "L2" "verify-config" --broadcast --legacy  -vvv --private-key "$DEPLOYER_PRIVATE_KEY"

echo "=== SCRIPT END ==="
