# Shared config template audit

Validation date: 2026-09-11. The full rerun completed successfully. Evidence is
stored in `/tmp/contracts-config-audit-hiy673zr/evidence`; see `summary.json`
for machine-readable results and `cli-tests.log` for the full CLI test results.

This audit covers `docker/templates/config.toml`, including how the local
contract scripts and `scroll-sdk-cli` consume the root configuration. The
baseline is the full template from commit
`56a4cacda6046c9445af023aefee15a42fda2fdd`. The audit ran the scripts in the
working tree, including `gen-configs.sh`, which no longer runs the legacy
coordinator generation step.

The template was reduced from **94 fields to 50 fields**: 46 fields were removed
and two supported ingress fields were added. Default account and database
values remain placeholders and must be populated for the enabled components.
Reth node identities are stored separately in doge-config.
Tests used only public test private keys and temporary local chains; they did
not read private keys from actual deployment directories.

DogeOS uses Dogecoin as its actual L1. The Ethereum/Scroll L1 contracts in the
deployment workflow are used for simulation and address derivation; they are
not deployed to Dogecoin. The removal of `[rollup]` follows from this L1
architecture and the fact that these parameters do not feed into L2 contracts.
It is unrelated to whether L2 uses Reth or Geth. The Reth node identity cleanup
below is a separate change. The retained legacy Ethereum/Scroll L1 initialization
path uses separate environment variables and is not part of the normal DogeOS
deployment workflow.

## The 46 removable fields

| Section                  | Removed fields                                                                                                                                                  | Rationale and limitations                                                                                                                                                                                                                                                 |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `general`                | `DA_PUBLISHER_ENDPOINT`, `BEACON_RPC_ENDPOINT`                                                                                                                  | Neither the current contract entry points nor the CLI consume these fields. Ethereum DA runtime configuration lives in doge-config.                                                                                                                                       |
| `general`                | `L1_RPC_ENDPOINT_WEBSOCKET`                                                                                                                                     | `setup domains` currently always outputs an empty string without reading the template value. The command may write the empty field back later.                                                                                                                            |
| `general`                | `VERIFIER_DIGEST_1`, `VERIFIER_DIGEST_2`                                                                                                                        | Deterministic deployment uses the `VERIFIER_DIGEST` constant in code. Legacy standalone Foundry scripts read environment variables with these names, not these two TOML fields.                                                                                           |
| `db`                     | `ADMIN_SYSTEM_DB_CONNECTION_STRING`                                                                                                                             | The CLI does not consume this name. The legacy admin mapping actually uses `ADMIN_SYSTEM_BACKEND_DB_CONNECTION_STRING`.                                                                                                                                                   |
| `gas-token`              | `GAS_ORACLE_INCORPORATE_TOKEN_EXCHANGE_RATE_ENANBLED`, `EXCHANGE_RATE_UPDATE_MODE`, `FIXED_EXCHANGE_RATE`, `TOKEN_SYMBOL_PAIR`, `ALTERNATIVE_GAS_TOKEN_ENABLED` | Current contracts do not consume these fields. The entire section and its automatic CLI mappings were removed. Optional compatibility reads in legacy CLI helper commands treat missing fields as false.                                                                  |
| `rollup`                 | `MAX_BLOCK_IN_CHUNK`, `MAX_BATCH_IN_BUNDLE`                                                                                                                     | `Configuration.sol` no longer reads these fields, and the automatic CLI mappings were also removed.                                                                                                                                                                       |
| `rollup`                 | `MAX_TX_IN_CHUNK`                                                                                                                                               | `ScrollChain.initialize` only writes to the deprecated, unread `__maxNumTxInChunk` storage slot. Configuration reads and CLI mappings were removed. Deployment scripts pass 0 to the ABI parameter retained for compatibility, without changing the storage layout.       |
| `rollup`                 | `TEST_ENV_MOCK_FINALIZE_TIMEOUT_SEC`                                                                                                                            | Current contract scripts do not read this field. Unused CLI reads of the mock switch and timeout, along with doge-config and spec mappings, were removed.                                                                                                                 |
| `rollup`                 | `MAX_L1_MESSAGE_GAS_LIMIT`, `FINALIZE_BATCH_DEADLINE_SEC`, `RELAY_MESSAGE_DEADLINE_SEC`                                                                         | These fields are used only to initialize L1 `SystemConfig` and do not feed into L2. Reads were removed from the shared loader. Explicit use of the legacy L1 initialization path now reads environment variables with the same names, matching the standalone L1 scripts. |
| `rollup`                 | `TEST_ENV_MOCK_FINALIZE_ENABLED`                                                                                                                                | This field only selects the L1 ScrollChain implementation. The branch was removed and the production implementation is always used, equivalent to the old template's false default. The entire `[rollup]` section was removed.                                            |
| `ingress`                | `ROLLUP_EXPLORER_API_HOST`, `COORDINATOR_API_HOST`, `ADMIN_SYSTEM_DASHBOARD_HOST`, `L1_EXPLORER_HOST`                                                           | These are legacy service domains. CLI prompts, mappings, TLS handling, and legacy values handling were removed. External Dogecoin explorer links are retained.                                                                                                            |
| `ingress`                | `BLOCKSCOUT_BACKEND_HOST`                                                                                                                                       | This field has no effective consumer. Both the current Blockscout UI and API use `BLOCKSCOUT_HOST`, routing to `/` and `/api` respectively.                                                                                                                               |
| `frontend`               | `BASE_CHAIN`                                                                                                                                                    | Both contract and CLI frontend outputs derive the base chain from `general.CHAIN_NAME_L1`.                                                                                                                                                                                |
| `genesis`                | `L2_MAX_ETH_SUPPLY`                                                                                                                                             | The canonical field `L2_MAX_NATIVE_DOGE_SUPPLY` is retained. Contracts support the old alias but do not require duplicate configuration.                                                                                                                                  |
| `contracts.verification` | `VERIFIER_TYPE_L1`, `EXPLORER_URI_L1`, `RPC_URI_L1`, `EXPLORER_API_KEY_L1`                                                                                      | The current verification entry point only verifies L2. `setup domains` may write L1 URLs back into the configuration, but does not depend on the old template values.                                                                                                     |
| `coordinator`            | `CHUNK_COLLECTION_TIME_SEC`, `BATCH_COLLECTION_TIME_SEC`, `BUNDLE_COLLECTION_TIME_SEC`                                                                          | The current Docker entry point no longer runs the legacy `GenerateCoordinatorConfig`. Anyone manually running that standalone legacy generator must still supply these fields.                                                                                            |

The cleanup for exclusive use of Reth removed another five fields from the
original template:

- `sequencer.L2GETH_KEYSTORE`, `sequencer.L2GETH_PASSWORD`, `sequencer.L2GETH_NODEKEY`.
- `bootnode.bootnode-0.L2GETH_NODEKEY`, `bootnode.bootnode-0.L2_GETH_STATIC_PEERS`.

The entire `[sequencer]` and `[bootnode.bootnode-0]` sections were removed. The
corresponding CLI changes removed legacy node generation, secret generation,
and peer fallbacks. Public P2P commands now read Reth bootnode configuration.
Reth signer and nodekey data are stored in `.data/doge-config.toml` and managed
by dedicated setup commands. `L2GETH_SIGNER_ADDRESS` and `L1_PLONK_VERIFIER_ADDR`
were already absent from this baseline template and are not counted among the
46 fields. Current contract generation does not require them, and the CLI no
longer requires users to fill them in.

The legacy service cleanup removed another five fields:

- `db.BRIDGE_HISTORY_DB_CONNECTION_STRING`, `db.CHAIN_MONITOR_DB_CONNECTION_STRING`,
  `db.L1_EXPLORER_DB_CONNECTION_STRING`: the CLI no longer initializes these
  databases or users, updates their permissions, or maps them to secrets.
- `frontend.BRIDGE_API_URI`, `ingress.BRIDGE_HISTORY_API_HOST`: the corresponding
  CLI domain prompts, legacy service values, and frontend configuration mappings
  were removed. `Configuration.sol` no longer reads this frontend field, and
  `GenerateConfigs.s.sol` no longer generates `REACT_APP_BRIDGE_API_URI`.

Blockbook was not present in the baseline template and does not affect the
counts above. The corresponding CLI changes removed its configuration, prompts,
secret/values generation, and network fallbacks. Wallet UTXO synchronization
uses Electrs, while bridge initialization reads transaction bytes through
Dogecoin RPC. See [`docs/config-cleanup.md`](../../scroll-sdk-cli/docs/config-cleanup.md)
in the adjacent CLI repository for the full operating instructions.

Further database consolidation removed three more template fields:
`GAS_ORACLE_DB_CONNECTION_STRING`, `COORDINATOR_DB_CONNECTION_STRING`, and
`ROLLUP_NODE_DB_CONNECTION_STRING`. The CLI also removed these connections,
Scroll, Rollup Explorer, and Admin System DSN aliases, and their secret mappings.
Legacy database dependency charts are no longer generated automatically.
The current `fee-oracle` and `proof-coordinator` services retain their own native
service configuration.

## Intentionally retained fields

- `general.L1_RPC_ENDPOINT`, `L2_RPC_ENDPOINT`: the CLI configures service RPC
  endpoints. These fields cannot be removed merely because the contract deploy
  image uses environment variables.
- `L1_CONTRACT_DEPLOYMENT_BLOCK`: the CLI still writes this value back and
  maintains compatibility mappings.
- Only `db.BLOCKSCOUT_DB_CONNECTION_STRING` is retained for the Blockscout secret;
  `db-init` also initializes only this database.
- `frontend.ETH_SYMBOL`, `CONNECT_WALLET_PROJECT_ID`: the CLI writes these into
  frontend outputs.
- Supported ingress fields: CLI domain and chart update paths are retained.
  `TSO_HOST` and `PROOF_COORDINATOR_HOST` were added for ports 3000 and 7788.
  For the latter, the native proof workflow enables ingress in active proof mode
  when a host is explicitly configured. TLS commands cover both hosts.
- `L1_FEE_VAULT_ADDR`: still used for genesis/bootstrap initialization and affects
  generated outputs.
- `FEE_VAULT_DOGE_RECIPIENT_ADDR`: the final fee vault Dogecoin P2PKH hash160.
  The zero value in the template is only a placeholder; actual initialization
  requires a nonzero value.
- `L2_BRIDGE_FEE_RECIPIENT_ADDR`: a zero value selects the L2 fee vault as Moat's
  fee recipient.
- `SCALAR`: although it belongs to the legacy formula, the configuration read
  and `setScalar` call still exist. Removing only the TOML field is insufficient.
- Genesis parameters and six predeploy overrides: still read by scripts or used
  to determine predeployment results.
- L2 verification configuration: the configuration entry point for current
  verification commands. The API key may be empty.

`setup generate-from-spec` was also updated to generate native Reth values and
no longer maps legacy Geth node fields from the root configuration. Other
service mappings may still generate optional fields that are not prepopulated
in the template. Removing template placeholders does not remove the runtime
services' own configuration requirements.

## Validation performed

| Check                                                                                 | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Run the current `docker/scripts/gen-configs.sh` with the original and new templates   | Both succeeded.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `config-contracts.toml`                                                               | Byte-for-byte identical.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `frontend-config.yaml`                                                                | Byte-for-byte identical.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Genesis                                                                               | Full JSON comparison matched, excluding only `timestamp`, which the generator sets to the current time.                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Compare with saved artifacts and on-chain snapshots from before the changes           | Contract addresses, frontend outputs, genesis (excluding timestamp), runtime code at 31 addresses, and 16 state values matched.                                                                                                                                                                                                                                                                                                                                                                                                             |
| Start a temporary Anvil instance with each genesis and run `docker/scripts/deploy.sh` | Both completed actual L2 transaction broadcasts and initialization.                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Code after deployment                                                                 | Runtime code matched at 31 L2 contract/predeploy addresses.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| State after deployment                                                                | All 16 reads matched: owner, fee vault recipient/messenger, Moat fees and minimum withdrawal, oracle whitelist, and four fee parameters.                                                                                                                                                                                                                                                                                                                                                                                                    |
| CLI `setup gen-keystore`, `l2-sequencer-reth`, `l2-bootnode-reth`                     | Both templates completed account and Reth node identity configuration, using only fixed public test keys.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| CLI `setup gen-secrets -N --json`                                                     | Both templates succeeded. All 11 secret files were byte-for-byte identical. Assertions confirmed that only Reth node secrets were present, with no legacy Geth node secrets.                                                                                                                                                                                                                                                                                                                                                                |
| CLI `setup prep-charts -N --json --skip-auth-check`                                   | Both templates succeeded. Reth node, contracts, Blockscout, and frontend values matched. RPC trustedPeers contained only Reth sequencers.                                                                                                                                                                                                                                                                                                                                                                                                   |
| CLI `setup domains -N --json --no-bootstrap-tls`                                      | Both templates succeeded. All 11 values files were byte-for-byte identical after the six command runs, including host/TLS updates for TSO and Proof Coordinator.                                                                                                                                                                                                                                                                                                                                                                            |
| CLI `setup gen-l2-artifacts --contracts-source`                                       | After the earlier removal of the entire `[rollup]` section, the actual command generated artifacts using the source and 53-field template available at that time in about 48.2 seconds, including compilation. Addresses and genesis matched this deployment audit, and the source checkout's `volume/config.toml` was unchanged. Evidence: `/tmp/rollup-cli-local-rpbvsfzk/summary.json`. Two earlier runs verified cache reuse in about 41.6 seconds / 2.6 seconds; evidence: `/tmp/scrollsdk-local-contracts-e2e-hf9dflud/summary.json`. |
| CLI `setup gen-rpc-package`                                                           | The full command regression passed, using native Reth genesis with no legacy Geth values. kubectl used local fixtures.                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Helm rendering of Reth values                                                         | Sequencer, bootnode, internal RPC, and public RPC values all rendered successfully with the local `l2-reth` chart.                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Contract verification script tests                                                    | 10 passed, including a check that the template can construct 21 L2 verification calls.                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Foundry genesis/fee-oracle configuration tests                                        | 7 passed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| CLI `setup db-init`                                                                   | Isolated PostgreSQL client regressions covered initialization, clean, permission updates, and port updates. Only Blockscout was operated on, even when legacy database DSNs/switches were supplied. No real database was connected.                                                                                                                                                                                                                                                                                                         |
| CLI `setup doge-config`                                                               | New configuration creation and migration of existing configurations both passed regression checks through the actual command entry point. RPC used local response fixtures; no Blockbook prompts or fields remained.                                                                                                                                                                                                                                                                                                                        |
| Full CLI test suite                                                                   | 560 passed, with 13 existing pending tests. See `cli-tests.log`, including regressions for the cleanup for exclusive use of Reth.                                                                                                                                                                                                                                                                                                                                                                                                           |

An additional parameter variation experiment used the scripts from before the
changes: the three numeric values were set to `123456`, `123`, and `456`, and
the mock switch was set to `true`. L2 artifacts were regenerated and actually
deployed. Compared with the previous defaults, only
`L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR` changed. All L2 addresses, genesis
(excluding timestamp), runtime code at 31 addresses, and 16 state values
remained unchanged. Evidence:
`/tmp/rollup-old-input-probe-wcm1hlu6/evidence/summary.json`.
These four settings therefore neither feed into L2 nor indirectly change L2
deployment results through the choice of L1 implementation.

Additional ingress validation covered preservation of explicit TSO and Proof
Coordinator hosts with shared or separate domains, the actual TLS command
(using read-only kubectl fixtures), Blockscout routing through a single domain,
and generation of host/TLS/7788 routes from active proof configuration with
initially disabled ingress. It also verified that inconsistent worker URLs
are rejected before compilation. Proof Coordinator configuration regressions
used compiler bundle fixtures; they do not represent running a prover in a
real cluster. Both services rendered successfully using the actual Helm charts
in the adjacent SDK repository: TSO targets Service `tso-service:3000`, and
Proof Coordinator targets `proof-coordinator:7788`, with matching host and
TLS hosts. The common chart requires a numeric ingress backend port. The
corresponding configuration disables the inherited empty HTTP port and selects
the prover port as the primary port. Rendered files and check summaries are
stored under `ingress-render/` in this audit's evidence directory.

The CLI build and lint checks for files changed in the audit passed.
Repository-wide lint still reported 10 pre-existing errors in the unchanged
`src/utils/kms-signer-provisioner.ts` and
`test/utils/kms-signer-provisioner.test.ts`.

Negative tests removed fields to verify that the comparisons detect problems:

- Removing `L2_GAS_ORACLE_SENDER_ADDR`, `L2_NATIVE_DOGE_TOKEN`, `SCALAR`, or
  `GRAFANA_URI` caused generation to fail with an error identifying the missing
  field.
- Removing `general.L2_RPC_ENDPOINT` could still leave the CLI reporting success,
  but the RPC endpoint in `contracts-production.yaml` was not updated correctly,
  and the output comparison detected the difference.
- Removing `db.BLOCKSCOUT_DB_CONNECTION_STRING` could still leave the CLI
  reporting success, but `blockscout-secret.env` was missing, and the output
  comparison detected the difference.

This was local validation of configuration-to-artifact generation, transaction
broadcasts for deployment, and resulting state. Anvil is not equivalent to a
complete Dogecoin/Reth network. This audit did not rerun Bridge creation,
actual withdrawals, KMS/IAM operations, database creation, or Kubernetes
installation. Those surrounding CLI capabilities were covered by existing
tests and configuration-consumer checks; this audit does not claim full
end-to-end validation against all real external systems. Explorer verification
submissions were mocked; no requests were sent to external explorers.
The actual Docker shell entry points ran locally; no new images were built or
pushed.

## Reproduction

Install dependencies in both repositories, build the CLI, and make sure
Python 3.11+, Node.js, Foundry (`forge` / `anvil` / `cast`), and `jq` are available:

```bash
python docker/scripts/test-config-template.py \
  --cli-repo ../scroll-sdk-cli
```

To also compare results before and after the script changes, append
`--previous-evidence /tmp/contracts-config-audit-7u_vsl7c/evidence`, pointing to
the evidence directory saved by a successful audit before the changes.
The full validation reported here included this comparison.

The script copies the current contract working tree into a temporary directory
and uses the fixed legacy template as its baseline. Each local Anvil chain uses
a random loopback port and shuts down when finished. Logs, test inputs, outputs,
and `summary.json` are saved in the reported `Evidence:` directory. Use `--output`
to specify a new directory that does not yet exist.

The contract logic that reads the template must be released alongside it and
included in new images. Replacing only the template while continuing to use
older images that lack these changes is insufficient.

## 2026-09-29 fee targets for fresh deployments

`scroll-sdk/examples/config.toml.example` and `docker/templates/config.toml`
carry the same launch fee inputs. `genesis.GAS_LIMIT = 30000000` is consumed by
`Configuration` / `GenerateGenesis` and written into the genesis header;
configs without this optional key retain the JSON template's legacy gas limit.
Commit scalar `600000000`, blob scalar `7400000000` and penalty factor `10000`
are written into the oracle predeploy's genesis storage.

`contracts.L2_BASE_FEE_OVERHEAD = 420000000000` is consumed by
`DeployScroll.initializeL2SystemConfig`, after the proxy is deployed and before
ownership transfer. This is a bootstrap transaction, not genesis predeploy
storage. The script applies the value only when the key is supplied and the
current value differs. `genesis.BASE_FEE_PER_GAS` remains a separate initial
header value. The L1 interface also consumes that header-fee input.

Build both gen-configs and deploy images with these script changes for mainnet;
old released images do not consume the new keys. CLI config rewriting preserves
these native TOML inputs without adding defaults or service-policy fields.
A rollup-node binary supporting the selected D48/E10 and 420,000 gwei cap is
still required. The earlier template-equivalence audit above predates these
intentional genesis and initial-state changes.
