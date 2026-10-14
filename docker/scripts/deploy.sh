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
# Broadcast bootstrap transactions in batches of up to 100 by default.
BATCH_SIZE="${BATCH_SIZE:-100}"

# Use the same transaction type for the L2 simulation and broadcast.
DEPLOY_LEGACY="${DEPLOY_LEGACY:-false}"
case "$DEPLOY_LEGACY" in
    true) set -- --legacy ;;
    false) set -- ;;
    *) echo "DEPLOY_LEGACY must be true or false" >&2; exit 1 ;;
esac

# Forge prices all transactions before broadcasting. The overhead write raises
# the base fee before the eight ownership transfers, so reserve 2x headroom.
node - "$CONFIG_FILE" <<'NODE'
const fs = require("fs");
const toml = require("toml");
function fail(message) {
    console.error(`Deployment gas check failed: ${message}`);
    process.exit(1);
}
let config;
try {
    config = toml.parse(fs.readFileSync(process.argv[2], "utf8"));
} catch {
    fail("cannot read or parse volume/config.toml");
}
// Match Configuration.sol: an omitted overhead defaults to zero.
const overhead = config.contracts?.L2_BASE_FEE_OVERHEAD ?? 0;
if (!Number.isSafeInteger(overhead) || overhead < 0) {
    fail("contracts.L2_BASE_FEE_OVERHEAD must be a non-negative safe integer in wei");
}
const minimum = 2n * BigInt(overhead);
const price = process.env.ETH_GAS_PRICE;
if (minimum === 0n && !price) process.exit(0);
if (!price || !/^[0-9]+$/.test(price)) {
    fail(`set ETH_GAS_PRICE to an integer in wei, at least ${minimum} (2 * L2_BASE_FEE_OVERHEAD)`);
}
if (BigInt(price) < minimum) {
    fail(`ETH_GAS_PRICE=${price} is too low; set it to at least ${minimum} wei (2 * L2_BASE_FEE_OVERHEAD) before deployment`);
}
console.log(`Deployment gas check passed: ETH_GAS_PRICE=${price} wei, minimum=${minimum} wei`);
NODE

echo "using L1_RPC_ENDPOINT = $L1_RPC_ENDPOINT"
echo "using L2_RPC_ENDPOINT = $L2_RPC_ENDPOINT"
echo "Environment variables:"
echo "FOUNDRY_EVM_VERSION: $FOUNDRY_EVM_VERSION"
echo "FOUNDRY_BYTECODE_HASH: $FOUNDRY_BYTECODE_HASH"
echo "BATCH_SIZE: $BATCH_SIZE"
echo "DEPLOY_LEGACY: $DEPLOY_LEGACY"

#simulate L1
echo ""
echo "simulating on L1"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --sig "run(string,string)" "None" "verify-config" 

# # deploy L1
# echo ""
# echo "deploying on L1"
# forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L1_RPC_ENDPOINT" --batch-size "${BATCH_SIZE}" --sig "run(string,string)" "L1" "verify-config" --broadcast --json 


# simulate L2
echo ""
echo "simulating on L2"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT" --sig "run(string,string)" "L2" "verify-config" "$@"


# deploy L2
echo ""
echo "deploying on L2"
# Foundry is pinned to the deploy image version in CI. --batch is Tempo-specific.
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --rpc-url "$L2_RPC_ENDPOINT"  --batch-size "$BATCH_SIZE" --sig "run(string,string)" "L2" "verify-config" --broadcast "$@" --json

echo "=== SCRIPT END ==="
