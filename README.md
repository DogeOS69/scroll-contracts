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

Then, run `foundryup` in a new terminal session or after reloading `PATH`.

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
guessing. The unused Standard/Custom ERC20, ERC721 and ERC1155 gateways, ERC20
template and factory remain excluded. Unconfigured deployment addresses are
reported as skipped; failed verifications are collected and produce a nonzero
exit status after the remaining contracts have been attempted.

Run `node --test docker/scripts/verify.test.js` to check the verification flow
using a mock forge executable, without submitting explorer requests.

## Build

- Run `git submodule update --init --recursive` to initialize git submodules.
- Run `yarn prettier:solidity` to run linting in fix mode, will auto-format all solidity codes.
- Run `yarn prettier` to run linting in fix mode, will auto-format all typescript codes.
- Run `yarn prepare` to install the precommit linting hook.
- Run `forge build --evm-version cancun` to compile contracts with foundry.
- Run `npx hardhat compile` to compile with hardhat.
- Run `forge test --evm-version cancun -vvv` to run foundry units tests. It will compile all contracts before running the unit tests.
- Run `npx hardhat test` to run integration tests. It may not compile all contracts before running, it's better to run `npx hardhat compile` first.
