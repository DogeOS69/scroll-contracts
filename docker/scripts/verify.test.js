const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");

const script = path.join(__dirname, "verify.sh");
const nativeToken = "0x530000000000000000000000000000000000d09e";
const config = `
[general]
CHAIN_ID_L2 = 938_471 # numeric separators and comments are valid TOML
RPC_URI_L2 = "http://wrong-section.invalid"
[contracts.overrides]
L2_NATIVE_DOGE_TOKEN = "${nativeToken}" # installed at genesis, not in config-contracts.toml
[contracts.verification]
RPC_URI_L2 = 'http://l2.invalid/rpc?token=a=b#fragment'
VERIFIER_TYPE_L2 = "blockscout"
EXPLORER_URI_L2 = "http://explorer.invalid/api/"
EXPLORER_API_KEY_L2 = "test key with spaces"
`;

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "verify l2 "));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, "volume"));
  fs.mkdirSync(path.join(directory, "bin"));
  const configPath = path.join(directory, "volume/config.toml");
  const addressesPath = path.join(directory, "volume/config-contracts.toml");
  const log = path.join(directory, "calls.jsonl");
  fs.writeFileSync(configPath, config);
  // Populate every template entry, including real L1 addresses and the ten L2
  // contracts deliberately excluded from verification. None may leak into calls.
  const template = fs.readFileSync(path.join(__dirname, "../templates/config-contracts.toml"), "utf8");
  let index = 0;
  const addresses = {};
  fs.writeFileSync(
    addressesPath,
    template
      .replace(/^(\w+_ADDR)\s*=\s*""/gm, (_, name) => {
        addresses[name] = `0x${(++index).toString(16).padStart(40, "0")}`;
        return `${name} = "${addresses[name]}" # deployed`;
      })
      .trimEnd() // The final address must also work without a trailing newline.
  );
  fs.writeFileSync(
    path.join(directory, "bin/forge"),
    `#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.VERIFY_TEST_LOG, JSON.stringify({ args, evm: process.env.FOUNDRY_EVM_VERSION, hash: process.env.FOUNDRY_BYTECODE_HASH }) + "\\n");
process.exit(process.env.VERIFY_TEST_FAIL === "all" || process.env.VERIFY_TEST_FAIL === args[2] ? 19 : 0);
`,
    { mode: 0o755 }
  );
  return {
    configPath,
    addressesPath,
    addresses,
    run(extraEnv = {}) {
      fs.writeFileSync(log, "");
      const result = spawnSync("bash", [script], {
        cwd: directory,
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${path.join(directory, "bin")}${path.delimiter}${process.env.PATH}`,
          VERIFY_TEST_LOG: log,
          ...extraEnv,
        },
      });
      assert.ifError(result.error);
      return {
        ...result,
        calls: fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse),
      };
    },
  };
}

test("verifies the 21 selected L2 contracts, including adapter and native predeploy", (t) => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 21);
  const byAddress = new Map(result.calls.map((call) => [call.args[1], call]));
  assert.equal(byAddress.get(f.addresses.L2_FEE_VAULT_MOAT_ADAPTER_ADDR).args[2], "FeeVaultMoatAdapter");
  assert.equal(byAddress.get(nativeToken).args[2], "NativeDogeToken");
  assert.equal(byAddress.get(f.addresses.L1_GAS_PRICE_ORACLE_ADDR).args[2], "L1GasPriceOracle");
  const excluded = Object.entries(f.addresses).filter(
    ([name]) =>
      (name.startsWith("L1_") && name !== "L1_GAS_PRICE_ORACLE_ADDR") ||
      /L2_(STANDARD_ERC20_GATEWAY|CUSTOM_ERC20_GATEWAY|ERC721_GATEWAY|ERC1155_GATEWAY|SCROLL_STANDARD_ERC20)/.test(name)
  );
  for (const [name, address] of excluded) assert.equal(byAddress.has(address), false, name);
  for (const call of result.calls) {
    assert.equal(call.args[call.args.indexOf("--chain-id") + 1], "938471");
    assert.equal(call.args[call.args.indexOf("--rpc-url") + 1], "http://l2.invalid/rpc?token=a=b#fragment");
    assert.equal(call.args[call.args.indexOf("--api-key") + 1], "test key with spaces");
    assert.equal(call.args[call.args.indexOf("--verifier-url") + 1], "http://explorer.invalid/api");
    assert.equal(call.evm, "cancun");
    assert.equal(call.hash, "none");
    assert.equal(call.args.includes("#"), false);
  }
  assert.equal(result.stdout.includes("test key with spaces"), false);
  assert.match(result.stdout, /21 succeeded, 0 failed/);
});

test("genesis predeploys never guess constructor arguments; deployed adapter does", (t) => {
  const result = fixture(t).run();
  assert.equal(result.status, 0, result.stderr);
  const predeploys = [
    "L1GasPriceOracle",
    "L2MessageQueue",
    "Whitelist",
    "WrappedDoge",
    "L2TxFeeVault",
    "NativeDogeToken",
  ];
  for (const source of predeploys) {
    const call = result.calls.find(({ args }) => args[2] === source);
    assert.ok(call, source);
    assert.equal(call.args.includes("--guess-constructor-args"), false, source);
  }
  const adapter = result.calls.find(({ args }) => args[2] === "FeeVaultMoatAdapter");
  assert.ok(adapter.args.includes("--guess-constructor-args"));
});

test("all forge failures are reported and make the script fail", (t) => {
  const result = fixture(t).run({ VERIFY_TEST_FAIL: "all" });
  assert.equal(result.status, 1);
  assert.equal(result.calls.length, 21);
  assert.match(result.stdout, /0 succeeded, 21 failed/);
  assert.match(result.stderr, /Failed contracts:.*L2_FEE_VAULT_MOAT_ADAPTER_ADDR.*L2_NATIVE_DOGE_TOKEN_ADDR/);
});

test("one failed contract does not prevent later verifications or disappear behind successes", (t) => {
  const result = fixture(t).run({ VERIFY_TEST_FAIL: "Moat" });
  assert.equal(result.status, 1);
  assert.equal(result.calls.length, 21);
  assert.match(result.stdout, /20 succeeded, 1 failed/);
  assert.match(result.stderr, /Failed contracts: L2_MOAT_IMPLEMENTATION_ADDR/);
});

test("invalid selected addresses fail before any request is submitted", (t) => {
  const f = fixture(t);
  fs.appendFileSync(f.addressesPath, '\nL2_NATIVE_DOGE_TOKEN_ADDR = "0x0000000000000000000000000000000000000001"\n');
  // The genesis override is authoritative even if a stale exported entry exists.
  fs.writeFileSync(f.configPath, config.replace(nativeToken, "not-an-address"));
  const result = f.run();
  assert.equal(result.status, 1);
  assert.equal(result.calls.length, 0);
  assert.match(result.stderr, /Invalid contract address for L2_NATIVE_DOGE_TOKEN_ADDR/);
});

test("legacy configs without a NativeDogeToken override verify its protocol address", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.configPath, config.replace(/^L2_NATIVE_DOGE_TOKEN.*$/m, ""));
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 21);
  const native = result.calls.find(({ args }) => args[2] === "NativeDogeToken");
  assert.equal(native.args[1], nativeToken);
  assert.equal(native.args.includes("--guess-constructor-args"), false);
});

test("unconfigured deployment addresses are explicitly skipped", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.addressesPath, "");
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 1);
  assert.equal(result.calls[0].args[2], "NativeDogeToken");
  assert.match(result.stdout, /1 succeeded, 0 failed, 20 unconfigured/);
});

test("Sourcify with an empty API key receives no dangling --api-key argument", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.configPath, config.replace('"blockscout"', '"sourcify"').replace('"test key with spaces"', '""'));
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  for (const { args } of result.calls) {
    assert.equal(args.includes("--api-key"), false);
    assert.equal(args[args.indexOf("--verifier") + 1], "sourcify");
  }
});

test("malformed TOML stops verification without echoing config contents", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.configPath, config + '\nPRIVATE_KEY = "sensitive-unclosed-value');
  const result = f.run();
  assert.equal(result.status, 1);
  assert.equal(result.calls.length, 0);
  assert.match(result.stderr, /Cannot read TOML file.*config.toml at line/);
  assert.equal(result.stderr.includes("sensitive-unclosed-value"), false);
});
