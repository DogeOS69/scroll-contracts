# Scroll Contracts

This directory contains the solidity code for Scroll L1 bridge and rollup contracts and L2 bridge and pre-deployed contracts.

## Directory Structure

<pre>
├── <a href="./hardhat-test/">hardhat-test</a>: Hardhat integration tests
├── <a href="./lib/">lib</a>: External libraries and testing tools
├── <a href="./scripts">scripts</a>: Deployment scripts
├── <a href="./src">src</a>
│   ├── <a href="./src/gas-swap/">gas-swap</a>: Utility contract that allows gas payment in other tokens
│   ├── <a href="./src/interfaces/">interfaces</a>: Common contract interfaces
│   ├── <a href="./src/L1/">L1</a>: Contracts deployed on the L1 (Ethereum)
│   │   ├── <a href="./src/L1/gateways/">gateways</a>: Gateway router and token gateway contracts
│   │   ├── <a href="./src/L1/rollup/">rollup</a>: Rollup contracts for data availability and finalization
│   │   ├── <a href="./src/L1/IL1ScrollMessenger.sol">IL1ScrollMessenger.sol</a>: L1 Scroll messenger interface
│   │   └── <a href="./src/L1/L1ScrollMessenger.sol">L1ScrollMessenger.sol</a>: L1 Scroll messenger contract
│   ├── <a href="./src/L2/">L2</a>: Contracts deployed on the L2 (Scroll)
│   │   ├── <a href="./src/L2/gateways/">gateways</a>: Gateway router and token gateway contracts
│   │   ├── <a href="./src/L2/predeploys/">predeploys</a>: Pre-deployed contracts on L2
│   │   ├── <a href="./src/L2/IL2ScrollMessenger.sol">IL2ScrollMessenger.sol</a>: L2 Scroll messenger interface
│   │   └── <a href="./src/L2/L2ScrollMessenger.sol">L2ScrollMessenger.sol</a>: L2 Scroll messenger contract
│   ├── <a href="./src/libraries/">libraries</a>: Shared contract libraries
│   ├── <a href="./src/misc/">misc</a>: Miscellaneous contracts
│   ├── <a href="./src/mocks/">mocks</a>: Mock contracts used in the testing
│   ├── <a href="./src/rate-limiter/">rate-limiter</a>: Rater limiter contract
│   └── <a href="./src/test/">test</a>: Unit tests in solidity
├── <a href="./foundry.toml">foundry.toml</a>: Foundry configuration
├── <a href="./hardhat.config.ts">hardhat.config.ts</a>: Hardhat configuration
├── <a href="./remappings.txt">remappings.txt</a>: Foundry dependency mappings
...
</pre>

## Dependencies

### Docker configuration template

[`docker/templates/config.toml`](docker/templates/config.toml) is shared by the
contract image entrypoints and `scroll-sdk-cli`. The current template has 50
fields (46 original entries removed, two active ingress hosts added); see the [field audit and validation record](docs/config-template-audit.md).
Deployment RPC selection comes from the `L2_RPC_ENDPOINT` environment variable
passed to the deploy image. The root TOML RPC fields remain necessary for CLI
service configuration. L2 verification uses `contracts.verification.RPC_URI_L2`.

`docker/scripts/deploy.sh` broadcasts L2 bootstrap transactions in batches of 100
by default. Set the `BATCH_SIZE` environment variable to override this, for example
`BATCH_SIZE=7 bash docker/scripts/deploy.sh`. Unset or empty values use 100.
With the default genesis predeploys, a fresh deployment creates nine contracts:
the Messenger, Moat and L2SystemConfig implementation/proxy pairs, ProxyAdmin,
the temporary empty implementation, and FeeVaultMoatAdapter. Legacy Scroll asset
gateways, the gateway router and the standard ERC20 template/factory are omitted,
including their initialization, routing and ownership settings. Regenerating
`config-contracts.toml` clears their old addresses; their frontend settings are empty.
All L2 configuration completes before ownership is transferred. The configured
`L2_BASE_FEE_OVERHEAD` is applied last in that configuration phase, followed by
the ownership transfers in `transferL2ContractOwnership()`.

The DogeOS audit scope remains included in bootstrap:

| Audited source                              | Included through                                                        |
| ------------------------------------------- | ----------------------------------------------------------------------- |
| `Moat.sol`                                  | Implementation and proxy deployed by `deploy.sh`                        |
| `L2DogeOsMessenger.sol`                     | Implementation and proxy deployed by `deploy.sh`                        |
| `FeeVaultMoatAdapter.sol`                   | Standalone contract deployed by `deploy.sh`                             |
| `NativeDogeToken.sol`                       | Genesis predeploy at `0x530000000000000000000000000000000000d09e`       |
| `WrappedDoge.sol`                           | WDOGE genesis predeploy at `0x5300000000000000000000000000000000000004` |
| `DogeAddressLib.sol`                        | Internal library compiled into Moat                                     |
| `WithdrawalEnvelope.sol`                    | Internal library compiled into Moat and L2DogeOsMessenger               |
| `libraries/common/AppendOnlyHashChain.sol`  | Base contract inherited by the L2MessageQueue genesis predeploy         |

Removing the legacy WETH gateway does not remove WDOGE. The bootstrap integration
test requires the audited deployment entries and checks the token/queue genesis
code and Native DOGE supply initialization.

L2 simulation and broadcast use EIP-1559 transactions by default. Set
`DEPLOY_LEGACY=true` in the deploy container's environment to explicitly use
legacy transactions; `false` (or unset) selects EIP-1559. Other values are rejected
before deployment starts. `ETH_GAS_PRICE` is the max fee per gas in EIP-1559 mode
and the fixed gas price in legacy mode. Set `ETH_PRIORITY_GAS_PRICE` separately
to control the EIP-1559 tip.

Before running Forge, `deploy.sh` requires `ETH_GAS_PRICE` to be an integer in wei
and at least twice `contracts.L2_BASE_FEE_OVERHEAD` from `volume/config.toml`.
With the default 420 gwei overhead, set it to at least `840000000000` (840 gwei).
Forge prices the transactions before broadcasting, so automatic pricing based on
the initial low base fee can leave the eight ownership transfers underpriced
after the overhead update. The 2x margin is a deployment policy, not a guarantee
against arbitrary base-fee increases. In EIP-1559 mode, the actual price remains
the block base fee plus tip, capped by `ETH_GAS_PRICE`. If overhead is zero or
omitted, automatic pricing is allowed. For example:

```sh
# EIP-1559: 840 gwei max fee, 1 gwei priority fee.
ETH_GAS_PRICE=840000000000 ETH_PRIORITY_GAS_PRICE=1000000000 bash docker/scripts/deploy.sh

# Legacy: fixed 840 gwei gas price.
DEPLOY_LEGACY=true ETH_GAS_PRICE=840000000000 bash docker/scripts/deploy.sh
```

Run `python3 scripts/integration/test-bootstrap.py` to exercise both Docker
entrypoints against an ephemeral Anvil, including the deployment inventory,
transaction ordering, core wiring and a 10 DOGE deployer budget. It defaults to
EIP-1559; pass `--legacy true` to check legacy transactions. This test does not
emulate the DogeOS client's base-fee-overhead algorithm.

The database section retains only `BLOCKSCOUT_DB_CONNECTION_STRING`. Bridge History, Chain Monitor and L1 Explorer database
settings have been removed, together with the Bridge History API frontend URL
and ingress host. CLI database initialization handles Blockscout only. The frontend generator no longer reads or emits the bridge API URL.

Reth node identities belong in `.data/doge-config.toml`; the root template has no
Geth sequencer/bootnode sections and requires neither `L2GETH_SIGNER_ADDRESS` nor
`L1_PLONK_VERIFIER_ADDR`. The CLI still consumes the remaining frontend/ingress
settings. `[gas-token]` has been removed because current contracts do not consume
its flag.

DogeOS uses Dogecoin as its actual L1. The Ethereum/Scroll L1 contracts in the
DogeOS deployment flow are simulated for deployment/address derivation. Removing
the entire `[rollup]` section follows from this L1 architecture, independently of
whether L2 uses Reth or Geth: its numeric fields only initialized legacy
Ethereum/Scroll L1 contracts, and the shared loader no longer reads them.
Deterministic generation always uses the real ScrollChain implementation. Explicit
legacy Ethereum/Scroll L1 initialization reads its three numeric settings from
environment variables; this standalone capability is separate from the normal
DogeOS workflow. L2 generation/deployment requires none of them. `MAX_TX_IN_CHUNK` was removed because
ScrollChain only writes it to an unused, deprecated storage slot. The canonical genesis supply field
is `genesis.L2_MAX_NATIVE_DOGE_SUPPLY`; the parser accepts the legacy
`L2_MAX_ETH_SUPPLY` alias in existing configurations.

The ingress template retains `BLOCKSCOUT_HOST` for both UI (`/`) and API (`/api`),
and now includes `TSO_HOST` and `PROOF_COORDINATOR_HOST`. The unused
`BLOCKSCOUT_BACKEND_HOST` and retired Rollup Explorer API, Coordinator API,
Admin Dashboard and L1 Explorer hosts are removed. Matching CLI domain/chart/TLS
commands configure the two active services; Proof Coordinator ingress targets
prover port 7788 in active proof mode, while TSO targets port 3000.

For local development, the CLI can run this checkout directly without an image:

```bash
# Run in the deployment directory containing config.toml.
scrollsdk setup gen-l2-artifacts --contracts-source /path/to/scroll-contracts \
  --non-interactive --json --skip-deployment-salt-update --skip-l1-fee-vault-update
```

This requires installed contract dependencies, Foundry and jq. It runs the same
generator entrypoint in an isolated project, preserves this checkout's `volume/`,
and reuses compiler outputs under the deployment's `.data/contracts-build/`.

Build matching contract images and the updated CLI together. The adjacent CLI
repository's [configuration and migration guide](../scroll-sdk-cli/docs/config-cleanup.md)
explains the removed prompts, supported inputs and local artifact cleanup.

The Docker generator produces contract addresses, genesis, and frontend config.
The genesis header timestamp comes from `genesis.TIMESTAMP` in `config.toml`
(Unix seconds, unsigned 64-bit integer). The template and older configs without
this key use `0`; generation never substitutes the current time. Set a fixed
nonzero value explicitly if the network needs a different genesis timestamp.
To reproduce a genesis, keep this value, `contracts.DEPLOYMENT_SALT`, all other
configuration, and the generator/compiler versions unchanged.

Changing the timestamp changes the genesis hash. Before launching a fresh
mainnet, regenerate the Reth mainnet genesis JSON, `DOGEOS_MAINNET_GENESIS_HASH`
and its test, the rollup-node chain spec, and matching release images/tag together
with the other pending genesis fixes. Do not replace an initialized network's
genesis as an upgrade.

Fresh genesis also installs the canonical EIP-2935 L2 history account for the
Feynman-at-genesis schedule. See [activation dependencies and RPC checks](docs/eip-2935.md).
The legacy standalone `GenerateCoordinatorConfig` generator reads its own
`coordinator.*_COLLECTION_TIME_SEC` settings and `general.L2_RPC_ENDPOINT` only
when invoked explicitly; callers of that generator must supply those fields.

### Fee-oracle deployment identity

The deterministic deployment scripts require only a valid, nonzero
`accounts.L2_GAS_ORACLE_SENDER_ADDR` for the L2 fee oracle. They authorize this
address in the L2 Whitelist but do not sign transactions as that service.
`L2_GAS_ORACLE_SENDER_PRIVATE_KEY` is neither required nor read from TOML or the
environment, allowing AWS KMS/HSM-managed service keys. Configure the service's
signing backend separately through scroll-sdk-cli.

The deployment scripts no longer read L1 commit-sender or finalize-sender
addresses or private keys, or register those accounts through
`ScrollChain.addSequencer()` or `ScrollChain.addProver()`. The unused L1 gas-oracle
sender is fixed to the zero address, is not whitelisted, and requires no address
or private-key configuration. Deployer account requirements are unchanged.

The legacy `L2GETH_SIGNER_ADDRESS` is fixed to the zero address and is not read
from TOML or the environment. SystemConfig initialization uses that zero signer;
genesis keeps `extraData` empty.

`COORDINATOR_JWT_SECRET_KEY` is fixed to `dogeos-coordinator-jwt-secret` in the
standalone coordinator generator and is not read from TOML or the environment.
Generated coordinator configurations use that value for `auth.secret`.

### Node.js

First install [`Node.js`](https://nodejs.org/en) and [`npm`](https://www.npmjs.com/).
Run the following command to install [`yarn`](https://classic.yarnpkg.com/en/):

```bash
npm install --global yarn
```

### Foundry

Install `foundryup`, the Foundry toolchain installer:

```bash
curl -L https://foundry.paradigm.xyz | bash
```

If you do not want to use the redirect, feel free to manually download the `foundryup` installation script from [here](https://raw.githubusercontent.com/foundry-rs/foundry/master/foundryup/foundryup).

Then, run `foundryup -i v1.3.0-rc2` in a new terminal session or after reloading
`PATH`. This matches the version pinned in CI and `docker/Dockerfile.base`.

Other ways to install Foundry can be found [here](https://github.com/foundry-rs/foundry#installation).

### Hardhat

Run the following command to install [Hardhat](https://hardhat.org/) and other dependencies.

```
yarn install
```

## Verify L2 contracts

From the repository root, run `bash docker/scripts/verify.sh` with Node.js, the
installed project dependencies, Foundry, and the deployment files in `volume/`.
The script reads L2 RPC/explorer settings from `[contracts.verification]` in
`config.toml` and deployed addresses from `config-contracts.toml`.
`NativeDogeToken` uses `[contracts.overrides].L2_NATIVE_DOGE_TOKEN` instead,
defaulting to the protocol address `0x530000000000000000000000000000000000d09e`
when the override is absent from older deployment configurations.

The verification list includes `FeeVaultMoatAdapter` and the L2 predeploys,
including `L1GasPriceOracle`. Genesis predeploys do not use constructor-argument
guessing. Legacy asset gateways, the gateway router, ERC20 template and factory
remain excluded. Unconfigured deployment addresses are
reported as skipped; failed verifications are collected and produce a nonzero
exit status after the remaining contracts have been attempted.

The same command also checks the EIP-2935 history account at its fixed protocol
address using `cast`: exact canonical runtime and nonce `1`, read at the same
block hash. This is a bytecode/account check, not explorer Solidity source
verification: the history runtime is hand-written EVM code, and the
`BlockHashHistory` Solidity library only holds constants. Missing or mismatching
history code, an incorrect nonce, or an RPC failure makes the command fail,
including for older configs without a history-account entry. History contents
are checked separately by [the RPC smoke test](docs/eip-2935.md).

Run `node --test docker/scripts/verify.test.js` to check the verification flow
using mock forge and cast executables, without submitting explorer or RPC requests.

## Build

- Run `git submodule update --init --recursive` to initialize git submodules.
- Run `yarn prettier:solidity` to run linting in fix mode, will auto-format all solidity codes.
- Run `yarn prettier` to run linting in fix mode, will auto-format all typescript codes.
- Run `yarn prepare` to install the precommit linting hook.
- Run `forge build --evm-version cancun` to compile contracts with foundry.
- Run `npx hardhat compile` to compile with hardhat.
- Run `forge test --evm-version cancun -vvv` to run foundry units tests. It will compile all contracts before running the unit tests.
- Run `npx hardhat test` to run integration tests. It may not compile all contracts before running, it's better to run `npx hardhat compile` first.
