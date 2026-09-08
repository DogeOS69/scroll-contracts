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
configuration scripts and is not read from TOML or the environment. Generated
coordinator configurations use that value for `auth.secret`.

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
