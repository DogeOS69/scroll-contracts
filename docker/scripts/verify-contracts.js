const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const toml = require("toml");

// DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN; also supports older deployment configs
// that predate the NativeDogeToken genesis/hardfork export scripts.
const nativeDogeTokenAddress = "0x530000000000000000000000000000000000d09e";

// Canonical EIP-2935 runtime (not the compiled BlockHashHistory constants library).
// This account has no Solidity source or genesis creation transaction to verify.
const blockHashHistoryAddress = "0x0000f90827f1c53a10cb7a02335b175320002935";
const blockHashHistoryCode =
  "0x3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";

function verifyBlockHashHistory(rpc) {
  function readCast(args) {
    const result = spawnSync("cast", [...args, "--rpc-url", rpc], { encoding: "utf8", timeout: 30000 });
    // RPC diagnostics can contain credentials from the URL. Keep them out of logs.
    if (result.error || result.signal || result.status !== 0) {
      throw new Error(`cast ${args[0]} failed; check the L2 RPC and Foundry installation`);
    }
    return result.stdout.trim();
  }

  console.log(`Checking EIP-2935 history runtime and nonce at ${blockHashHistoryAddress} on L2`);
  // Bind both reads to the same block even if the head advances or reorganizes.
  const blockHash = readCast(["block", "latest", "--field", "hash"]);
  if (!/^0x[0-9a-fA-F]{64}$/.test(blockHash)) throw new Error("Invalid L2 block hash returned by cast");
  const code = readCast(["code", blockHashHistoryAddress, "--block", blockHash]);
  if (code.toLowerCase() !== blockHashHistoryCode) {
    throw new Error("EIP-2935 history runtime is missing or does not match the canonical bytecode");
  }
  const nonce = readCast(["nonce", blockHashHistoryAddress, "--block", blockHash]);
  if (nonce !== "1") throw new Error("EIP-2935 history account nonce must be 1");
  console.log(`EIP-2935 history: runtime and nonce verified at block ${blockHash} (no Solidity source verification)`);
}

// Only contracts used on L2 belong in this list. The unused ERC20/ERC721/ERC1155
// gateways and ERC20 factory/template intentionally remain excluded.
// L1GasPriceOracle is an L2 predeploy despite its L1_ configuration key.
const contracts = [
  ["L1_GAS_PRICE_ORACLE_ADDR", "L1GasPriceOracle", true],
  ["L2_MESSAGE_QUEUE_ADDR", "L2MessageQueue", true],
  ["L2_WHITELIST_ADDR", "Whitelist", true],
  ["L2_WDOGE_ADDR", "WrappedDoge", true],
  ["L2_TX_FEE_VAULT_ADDR", "L2TxFeeVault", true],
  ["L2_PROXY_ADMIN_ADDR", "ProxyAdminSetOwner", false],
  ["L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR", "EmptyContract", false],
  ["L2_DOGEOS_MESSENGER_PROXY_ADDR", "TransparentUpgradeableProxy", false],
  ["L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR", "L2DogeOsMessenger", false],
  ["L2_GATEWAY_ROUTER_PROXY_ADDR", "TransparentUpgradeableProxy", false],
  ["L2_GATEWAY_ROUTER_IMPLEMENTATION_ADDR", "L2GatewayRouter", false],
  ["L2_ETH_GATEWAY_PROXY_ADDR", "TransparentUpgradeableProxy", false],
  ["L2_ETH_GATEWAY_IMPLEMENTATION_ADDR", "L2ETHGateway", false],
  ["L2_WETH_GATEWAY_PROXY_ADDR", "TransparentUpgradeableProxy", false],
  ["L2_WETH_GATEWAY_IMPLEMENTATION_ADDR", "L2WETHGateway", false],
  ["L2_MOAT_PROXY_ADDR", "TransparentUpgradeableProxy", false],
  ["L2_MOAT_IMPLEMENTATION_ADDR", "Moat", false],
  ["L2_SYSTEM_CONFIG_PROXY_ADDR", "TransparentUpgradeableProxy", false],
  ["L2_SYSTEM_CONFIG_IMPLEMENTATION_ADDR", "L2SystemConfig", false],
  ["L2_FEE_VAULT_MOAT_ADAPTER_ADDR", "FeeVaultMoatAdapter", false],
  ["L2_NATIVE_DOGE_TOKEN_ADDR", "NativeDogeToken", true],
];

function readToml(file) {
  try {
    return toml.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    // Parser errors can include config values. Only report the file and location.
    const location = error.line ? ` at line ${error.line}, column ${error.column}` : "";
    throw new Error(`Cannot read TOML file ${file}${location}`);
  }
}

function requiredString(value, key) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Missing or invalid ${key}`);
  }
  return value.trim();
}

function main() {
  const config = readToml(path.resolve("volume/config.toml"));
  const addresses = readToml(path.resolve("volume/config-contracts.toml"));
  const verification = config.contracts?.verification || {};
  const chainId = config.general?.CHAIN_ID_L2;
  if (!Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new Error("Missing or invalid general.CHAIN_ID_L2");
  }
  const rpc = requiredString(verification.RPC_URI_L2, "contracts.verification.RPC_URI_L2");
  const verifier = requiredString(verification.VERIFIER_TYPE_L2, "contracts.verification.VERIFIER_TYPE_L2");
  if (!["blockscout", "etherscan", "sourcify"].includes(verifier)) {
    throw new Error(`Unsupported L2 verifier: ${verifier}`);
  }

  const options = [
    "--rpc-url",
    rpc,
    "--chain-id",
    String(chainId),
    "--watch",
    "--skip-is-verified-check",
    "--verifier",
    verifier,
  ];
  if (verifier !== "etherscan") {
    let url = requiredString(verification.EXPLORER_URI_L2, "contracts.verification.EXPLORER_URI_L2").replace(
      /\/+$/,
      ""
    );
    if (verifier === "blockscout" && !url.endsWith("/api")) url += "/api";
    options.push("--verifier-url", url);
  }
  const apiKey = verification.EXPLORER_API_KEY_L2;
  if (apiKey !== undefined && typeof apiKey !== "string") {
    throw new Error("Invalid contracts.verification.EXPLORER_API_KEY_L2");
  }
  if (apiKey) options.push("--api-key", apiKey);

  // NativeDogeToken is installed by genesis/hardfork tooling, so its address is
  // not exported by DeployScroll to config-contracts.toml. Like other predeploys,
  // verify runtime code without looking for a nonexistent creation transaction.
  addresses.L2_NATIVE_DOGE_TOKEN_ADDR = requiredString(
    config.contracts?.overrides?.L2_NATIVE_DOGE_TOKEN ?? nativeDogeTokenAddress,
    "contracts.overrides.L2_NATIVE_DOGE_TOKEN"
  );

  // Validate the entire selected list before submitting any verification request.
  const targets = [];
  const skipped = [];
  for (const [name, source, predeploy] of contracts) {
    const address = addresses[name];
    if (address === undefined || address === "") {
      skipped.push(name);
      continue;
    }
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address) || /^0x0{40}$/.test(address)) {
      throw new Error(`Invalid contract address for ${name}`);
    }
    targets.push({ name, source, predeploy, address });
  }

  for (const name of skipped) console.log(`Skipping ${name}: no address configured`);
  const failed = [];
  let verified = 0;
  for (const { name, source, predeploy, address } of targets) {
    console.log(`Verifying ${name} (${source}) at ${address} on L2`);
    const args = ["verify-contract", address, source, ...options];
    if (!predeploy) args.push("--guess-constructor-args");
    const result = spawnSync("forge", args, {
      stdio: "inherit",
      env: { ...process.env, FOUNDRY_EVM_VERSION: "cancun", FOUNDRY_BYTECODE_HASH: "none" },
    });
    if (result.error) throw new Error(`Cannot execute forge: ${result.error.code}`);
    if (result.signal) throw new Error(`forge interrupted by ${result.signal}`);
    if (result.status !== 0) {
      failed.push(name);
      console.error(`Verification failed for ${name} (exit ${result.status})`);
    } else {
      verified++;
    }
  }
  console.log(`L2 source verification: ${verified} succeeded, ${failed.length} failed, ${skipped.length} unconfigured`);
  if (failed.length) {
    console.error(`Failed contracts: ${failed.join(", ")}`);
    process.exitCode = 1;
  }
  // Always check the protocol address, including configs created before this
  // predeploy was added. A missing account must not be silently skipped.
  try {
    verifyBlockHashHistory(rpc);
  } catch (error) {
    console.error(`Verification failed for EIP-2935 history: ${error.message}`);
    process.exitCode = 1;
  }
}

try {
  main();
} catch (error) {
  console.error(`Error: ${error.message}`);
  process.exitCode = 1;
}
