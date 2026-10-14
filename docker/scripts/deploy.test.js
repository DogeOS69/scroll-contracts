const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { test } = require("node:test");

const script = path.join(__dirname, "deploy.sh");

function run(t, shell, mode, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "deploy-flags-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const log = path.join(directory, "calls.jsonl");
  fs.writeFileSync(log, "");
  fs.mkdirSync(path.join(directory, "volume"));
  if (options.config !== null) {
    fs.writeFileSync(
      path.join(directory, "volume/config.toml"),
      options.config ?? fs.readFileSync(path.join(__dirname, "../templates/config.toml"), "utf8")
    );
  }
  // Match the deploy image: the guard only needs Node and the TOML package.
  fs.mkdirSync(path.join(directory, "node_modules"));
  fs.symlinkSync(path.dirname(require.resolve("toml/package.json")), path.join(directory, "node_modules/toml"), "dir");
  fs.writeFileSync(
    path.join(directory, "forge"),
    `#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.DEPLOY_TEST_LOG, JSON.stringify(args) + "\\n");
if (args.includes("--batch")) process.exit(2);
`,
    { mode: 0o755 }
  );
  const env = {
    ...process.env,
    PATH: `${directory}${path.delimiter}${process.env.PATH}`,
    DEPLOY_TEST_LOG: log,
    L1_RPC_ENDPOINT: "http://l1.invalid:8545",
    L2_RPC_ENDPOINT: "http://l2.invalid:8545",
    ETH_GAS_PRICE: "840000000000",
  };
  delete env.DEPLOY_LEGACY;
  delete env.BATCH_SIZE;
  if (mode !== undefined) env.DEPLOY_LEGACY = mode;
  for (const [key, value] of Object.entries(options.env ?? {})) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  const result = spawnSync(shell, [script], { cwd: directory, env, encoding: "utf8" });
  assert.ifError(result.error);
  return {
    ...result,
    calls: fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map(JSON.parse),
  };
}

for (const shell of ["sh", "bash"]) {
  for (const mode of [undefined, "false", "true"]) {
    test(`${shell}: DEPLOY_LEGACY=${mode ?? "unset"}`, (t) => {
      const result = run(t, shell, mode);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.calls.length, 3);
      const [l1, simulation, broadcast] = result.calls;
      assert.ok(l1.includes("None"));
      assert.equal(l1.includes("--legacy"), false);
      for (const args of [simulation, broadcast]) {
        assert.ok(args.includes("L2"));
        assert.equal(args.includes("--legacy"), mode === "true");
        assert.equal(args.includes(""), false);
        assert.equal(args.includes("--batch"), false);
      }
      assert.equal(simulation.includes("--broadcast"), false);
      assert.ok(broadcast.includes("--broadcast"));
      assert.equal(broadcast[broadcast.indexOf("--batch-size") + 1], "100");
    });
  }
  test(`${shell}: reject an invalid mode before executing forge`, (t) => {
    const result = run(t, shell, "flase");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /DEPLOY_LEGACY must be true or false/);
    assert.deepEqual(result.calls, []);
  });
  for (const mode of ["false", "true"]) {
    for (const price of [undefined, "", "20000000000", "420100000000", "839999999999", "840gwei", "-1", "8.4e11"]) {
      test(`${shell}: reject ETH_GAS_PRICE=${price ?? "unset"}, legacy=${mode}`, (t) => {
        const result = run(t, shell, mode, { env: { ETH_GAS_PRICE: price } });
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /Deployment gas check failed:.*840000000000/);
        assert.deepEqual(result.calls, []);
      });
    }
    test(`${shell}: accept a price above the minimum, legacy=${mode}`, (t) => {
      const result = run(t, shell, mode, { env: { ETH_GAS_PRICE: "900000000000" } });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.calls.length, 3);
    });
  }
  test(`${shell}: derive the minimum from the mounted config`, (t) => {
    const options = { config: "[contracts]\nL2_BASE_FEE_OVERHEAD = 500_000_000_000\n" };
    const rejected = run(t, shell, "false", options);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /at least 1000000000000 wei/);
    assert.deepEqual(rejected.calls, []);
    const accepted = run(t, shell, "false", {
      ...options,
      env: { ETH_GAS_PRICE: "1000000000000" },
    });
    assert.equal(accepted.status, 0, accepted.stderr);
    assert.equal(accepted.calls.length, 3);
  });
  for (const config of ["[contracts]\nL2_BASE_FEE_OVERHEAD = 0\n", "[contracts]\n"]) {
    test(`${shell}: allow automatic pricing without overhead: ${config.trim()}`, (t) => {
      const result = run(t, shell, "false", { config, env: { ETH_GAS_PRICE: undefined } });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.calls.length, 3);
    });
  }
  for (const config of [
    null,
    "invalid TOML",
    "[contracts]\nL2_BASE_FEE_OVERHEAD = -1\n",
    "[contracts]\nL2_BASE_FEE_OVERHEAD = 1.5\n",
    "[contracts]\nL2_BASE_FEE_OVERHEAD = 9007199254740993\n",
  ]) {
    test(`${shell}: reject missing/invalid gas config: ${config}`, (t) => {
      const result = run(t, shell, "false", { config });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Deployment gas check failed/);
      assert.deepEqual(result.calls, []);
    });
  }
}
