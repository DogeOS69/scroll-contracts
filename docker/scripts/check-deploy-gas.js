// Forge prices all transactions before broadcasting. The overhead write raises
// the base fee before the eight ownership transfers, so reserve 2x headroom.
const fs = require("fs");
const toml = require("toml");
function fail(message) {
  throw new Error(message);
}

function main() {
  let config;
  try {
    config = toml.parse(fs.readFileSync(process.argv[2], "utf8"));
  } catch {
    fail("cannot read or parse volume/config.toml");
  }
  // Match Configuration.sol: an omitted overhead defaults to zero.
  const value = config.contracts?.L2_BASE_FEE_OVERHEAD ?? 0;
  // Configuration.sol also accepts quoted decimal integers through readUint.
  const overhead = typeof value === "string" && /^[0-9]+$/.test(value) ? Number(value) : value;
  if (!Number.isSafeInteger(overhead) || overhead < 0) {
    fail("contracts.L2_BASE_FEE_OVERHEAD must be a non-negative safe integer in wei");
  }
  const minimum = 2n * BigInt(overhead);
  const price = process.env.ETH_GAS_PRICE;
  if (minimum === 0n && !price) return;
  if (!price || !/^[0-9]+$/.test(price)) {
    fail(`set ETH_GAS_PRICE to an integer in wei, at least ${minimum} (2 * L2_BASE_FEE_OVERHEAD)`);
  }
  if (BigInt(price) < minimum) {
    fail(
      `ETH_GAS_PRICE=${price} is too low; set it to at least ${minimum} wei (2 * L2_BASE_FEE_OVERHEAD) before deployment`
    );
  }
  console.log(`Deployment gas check passed: ETH_GAS_PRICE=${price} wei, minimum=${minimum} wei`);
}

try {
  main();
} catch (error) {
  console.error(`Deployment gas check failed: ${error.message}`);
  process.exitCode = 1;
}
