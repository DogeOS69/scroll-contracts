const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { test } = require("node:test");

const script = path.join(__dirname, "deploy.sh");

function run(t, shell, mode, modernFoundry) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "deploy-flags-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const log = path.join(directory, "calls.jsonl");
  fs.writeFileSync(log, "");
  fs.writeFileSync(
    path.join(directory, "forge"),
    `#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(${JSON.stringify(
    modernFoundry ? "      --batch\n      --batch-size <BATCH_SIZE>" : "      --batch-size <BATCH_SIZE>"
  )});
  process.exit(0);
}
fs.appendFileSync(process.env.DEPLOY_TEST_LOG, JSON.stringify(args) + "\\n");
if (${modernFoundry} && args.includes("--batch-size") && !args.includes("--batch")) process.exit(2);
if (!${modernFoundry} && args.includes("--batch")) process.exit(2);
`,
    { mode: 0o755 }
  );
  const env = {
    ...process.env,
    PATH: `${directory}${path.delimiter}${process.env.PATH}`,
    DEPLOY_TEST_LOG: log,
    L1_RPC_ENDPOINT: "http://l1.invalid:8545",
    L2_RPC_ENDPOINT: "http://l2.invalid:8545",
  };
  delete env.DEPLOY_LEGACY;
  if (mode !== undefined) env.DEPLOY_LEGACY = mode;
  const result = spawnSync(shell, [script], { cwd: directory, env, encoding: "utf8" });
  assert.ifError(result.error);
  return {
    ...result,
    calls: fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map(JSON.parse),
  };
}

for (const shell of ["sh", "bash"]) {
  for (const modernFoundry of [false, true]) {
    for (const mode of [undefined, "false", "true"]) {
      test(`${shell}: DEPLOY_LEGACY=${mode ?? "unset"}, batch flag supported=${modernFoundry}`, (t) => {
        const result = run(t, shell, mode, modernFoundry);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.calls.length, 3);
        const [l1, simulation, broadcast] = result.calls;
        assert.ok(l1.includes("None"));
        assert.equal(l1.includes("--legacy"), false);
        for (const args of [simulation, broadcast]) {
          assert.ok(args.includes("L2"));
          assert.equal(args.includes("--legacy"), mode === "true");
          assert.equal(args.includes(""), false);
        }
        assert.equal(simulation.includes("--broadcast"), false);
        assert.equal(simulation.includes("--batch"), false);
        assert.ok(broadcast.includes("--broadcast"));
        assert.equal(broadcast[broadcast.indexOf("--batch-size") + 1], "100");
        assert.equal(broadcast.includes("--batch"), modernFoundry);
      });
    }
  }
  test(`${shell}: reject an invalid mode before executing forge`, (t) => {
    const result = run(t, shell, "flase", false);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /DEPLOY_LEGACY must be true or false/);
    assert.deepEqual(result.calls, []);
  });
}
