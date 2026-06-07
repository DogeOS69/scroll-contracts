# Moat Upgrade - P2SH Withdrawal Support

This document is split into two parts:

- **Operations:** commands and checks an operator should run.
- **Explanation:** why the upgrade is needed and how it works.

The target upgrade changes the L2 `Moat` proxy at `L2_MOAT_PROXY_ADDR` to the
`feat/p2sh-withdrawals` revision. It adds P2SH withdrawal support, a versioned
message envelope, and on-chain Base58Check address decoding.

Reference merge: [`3e29ab0`](../../commit/3e29ab0) (merges
`feat/p2sh-withdrawals` into `dogeos-v0.3.0-develop`, introduced by
[`4cfcad9`](../../commit/4cfcad9)).

---

## 1. Operations

Use this section during the actual upgrade. It intentionally focuses on what to
run and what to verify.

### 1.1 Operational summary

The live-chain upgrade has only two chain-changing actions:

| Action                                                    | Signer             | Script                                                                                       |
| --------------------------------------------------------- | ------------------ | -------------------------------------------------------------------------------------------- |
| Deploy the new `Moat` implementation                      | `DEPLOYER`         | `BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh`                                |
| Point the existing `Moat` proxy to the new implementation | `ProxyAdmin owner` | `OWNER_PRIVATE_KEY=... BROADCAST=1 scripts/deterministic/shell/submit-moat-proxy-upgrade.sh` |

The other steps are configuration selection, dry runs, preflight checks, and
post-upgrade verification. They are included to avoid upgrading the wrong
network, proxy, or implementation.

Current deterministic scripts do not support an environment-variable-only
configuration. Network values and contract addresses are read from:

- `volume/config.toml`
- `volume/config-contracts.toml`

Private keys are the intended environment-variable inputs. For this upgrade,
`DEPLOYER_PRIVATE_KEY` is used by the implementation deploy step, and
`OWNER_PRIVATE_KEY` is used by the ProxyAdmin upgrade step.

Use a symlink for `volume` during normal operations. Copying config files into a
local `volume` directory can work mechanically, but it creates a second copy of
`config-contracts.toml`; the implementation deploy step writes
`L2_MOAT_IMPLEMENTATION_ADDR` back to `volume/config-contracts.toml`, so a copy
can leave the target network's real config stale.

### 1.2 Operator checklist

Before sending any transaction:

- Check out the branch that contains this upgrade.
- Confirm the target network configuration is symlinked at `<repo-root>/volume`.
- Confirm the envelope-aware withdraw processor is already deployed.
- Confirm you control the `ProxyAdmin owner` key printed by the upgrade script.
- Run the dry-run commands first, then run the same flow with `BROADCAST=1`.

### 1.3 Fresh genesis / new chain

For a fresh chain, run the normal deploy pipeline from this branch. The deploy
script already deploys the new `Moat` implementation with the correct Dogecoin
prefixes and upgrades the proxy.

No extra manual Moat command is required for a fresh genesis deployment.

### 1.4 Live chain / existing deployment

Run all commands from the repository root unless noted otherwise.

#### Step 1 - Point `volume` at the target network

```bash
# Example for testnet. Replace the target path for another network.
ln -sfn ../dogeos-aws-testnet volume

# Verify the symlink.
ls -l volume
```

Expected shape:

```text
volume -> ../dogeos-aws-testnet
```

The scripts read:

- `volume/config.toml`
- `volume/config-contracts.toml`

#### Step 2 - Dry-run implementation deployment

```bash
scripts/deterministic/shell/deploy-moat-impl.sh
```

Check the printed values before continuing:

- L2 RPC
- `CHAIN_ID_L1`
- selected Dogecoin prefixes
- `L2_PROXY_ADMIN_ADDR`
- `L2_MOAT_PROXY_ADDR`
- current implementation
- predicted or target new implementation
- generated `upgrade(address,address)` calldata

Do not execute the proxy upgrade yet. A dry run can update
`L2_MOAT_IMPLEMENTATION_ADDR` in `volume/config-contracts.toml` with a predicted
deterministic address, but that implementation may not exist on-chain until the
broadcast step succeeds.

#### Step 3 - Broadcast implementation deployment

```bash
BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh
```

After this succeeds, confirm `volume/config-contracts.toml` contains the new:

```toml
L2_MOAT_IMPLEMENTATION_ADDR = "..."
```

#### Step 4 - Dry-run ProxyAdmin upgrade

```bash
scripts/deterministic/shell/submit-moat-proxy-upgrade.sh
```

Check the printed values before continuing:

- `ProxyAdmin owner`
- implementation before upgrade
- target implementation
- pre-upgrade storage snapshot: `messenger`, `basculeVerifier`,
  `withdrawalFee`, `minWithdrawalAmount`, `depositFee`, `feeRecipient`, `owner`

The target implementation must already have bytecode on-chain.

#### Step 5 - Broadcast ProxyAdmin upgrade

Use the private key for the ProxyAdmin owner. Do not hardcode the key into any
script file.

```bash
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-moat-proxy-upgrade.sh
```

The script sends:

```text
ProxyAdmin.upgrade(L2_MOAT_PROXY_ADDR, L2_MOAT_IMPLEMENTATION_ADDR)
```

No `initialize` call is needed.

#### Step 6 - Verify the upgrade

Set the RPC URL used for direct `cast` checks:

```bash
export L2_RPC=<L2_RPC>
```

Check the implementation address:

```bash
cast implementation <L2_MOAT_PROXY_ADDR> --rpc-url "$L2_RPC"
```

Expected result:

```text
<L2_MOAT_IMPLEMENTATION_ADDR>
```

Check the immutable Dogecoin prefixes:

```bash
cast call <L2_MOAT_PROXY_ADDR> 'P2PKH_PREFIX()(bytes1)' --rpc-url "$L2_RPC"
cast call <L2_MOAT_PROXY_ADDR> 'P2SH_PREFIX()(bytes1)'  --rpc-url "$L2_RPC"
```

Expected values:

| Network / L1 chainId | P2PKH prefix | P2SH prefix |
| -------------------- | ------------ | ----------- |
| Mainnet / `1`        | `0x1e`       | `0x16`      |
| Testnet / `111111`   | `0x71`       | `0xc4`      |
| Regtest / `5555555`  | `0x6f`       | `0xc4`      |

Check that key storage-backed values are preserved:

```bash
cast call <L2_MOAT_PROXY_ADDR> 'messenger()(address)'           --rpc-url "$L2_RPC"
cast call <L2_MOAT_PROXY_ADDR> 'withdrawalFee()(uint256)'       --rpc-url "$L2_RPC"
cast call <L2_MOAT_PROXY_ADDR> 'minWithdrawalAmount()(uint256)' --rpc-url "$L2_RPC"
cast call <L2_MOAT_PROXY_ADDR> 'owner()(address)'               --rpc-url "$L2_RPC"
```

Compare these values with the pre-upgrade snapshot printed in Step 4.

Check that a new entry point exists:

```bash
cast call <L2_MOAT_PROXY_ADDR> \
  'withdrawToP2SH(address)' \
  0x0000000000000000000000000000000000000001 \
  --rpc-url "$L2_RPC"
```

This static call may revert because it does not provide the required fee. That
is acceptable. The important check is that it does not fail as an unknown
function selector.

Finally, send one end-to-end withdrawal through each path and confirm the L1
side handles the envelope bytes correctly:

- `withdrawToP2PKH`
- `withdrawToP2SH`
- `withdrawToDogeAddress`

### 1.5 Manual implementation deployment fallback

Prefer the scripts above. Use this only if the deploy script cannot be used.

```bash
forge create src/dogeos/Moat.sol:Moat \
  --rpc-url <L2_RPC> \
  --private-key <DEPLOYER_KEY> \
  --constructor-args <P2PKH_PREFIX> <P2SH_PREFIX>
```

Record the returned address as:

```text
L2_MOAT_IMPLEMENTATION_ADDR
```

Use the network-correct constructor args:

| Network / L1 chainId | P2PKH prefix | P2SH prefix |
| -------------------- | ------------ | ----------- |
| Mainnet / `1`        | `0x1e`       | `0x16`      |
| Testnet / `111111`   | `0x71`       | `0xc4`      |
| Regtest / `5555555`  | `0x6f`       | `0xc4`      |

### 1.6 Manual ProxyAdmin upgrade fallback

Prefer `submit-moat-proxy-upgrade.sh`. Use this only if the upgrade script
cannot be used.

```bash
cast send <L2_PROXY_ADMIN_ADDR> \
  'upgrade(address,address)' \
  <L2_MOAT_PROXY_ADDR> <L2_MOAT_IMPLEMENTATION_ADDR> \
  --rpc-url <L2_RPC> \
  --private-key <PROXY_ADMIN_OWNER_KEY> \
  --legacy
```

### 1.7 Rollback command

Rollback points the proxy back to the previous implementation address:

```bash
cast send <L2_PROXY_ADMIN_ADDR> \
  'upgrade(address,address)' \
  <L2_MOAT_PROXY_ADDR> <L2_MOAT_IMPLEMENTATION_ADDR_OLD> \
  --rpc-url <L2_RPC> \
  --private-key <PROXY_ADMIN_OWNER_KEY> \
  --legacy
```

Before rollback, confirm the withdraw processor can safely handle any
already-queued `version=1` envelope withdrawals.

---

## 2. Explanation

Use this section to understand what the upgrade changes and why the operational
ordering matters.

### 2.1 What changes

#### New withdrawal entry points

| Function                        | Behavior                                                                                                                                                                  |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `withdrawToL1(address)`         | Behavior change. Still P2PKH, but now attaches a 2-byte envelope with `flags=0` instead of empty bytes. Kept for backward compatibility; prefer the typed variants below. |
| `withdrawToP2PKH(address)`      | New. Semantic alias of `withdrawToL1`; payload is the 20-byte hash160 of the recipient's pubkey.                                                                          |
| `withdrawToP2SH(address)`       | New. Payload is the 20-byte hash160 of the redeem script; envelope flags are `0x01`.                                                                                      |
| `withdrawToDogeAddress(string)` | New. Accepts a full Base58Check-encoded Dogecoin address; the contract decodes it on-chain via `DogeAddressLib` and routes to P2PKH or P2SH based on the version byte.    |

All four entry points use the common `_processWithdrawal(target, isP2SH)` path:

1. Validate fee and minimum withdrawal amount.
2. Transfer the fee.
3. Call `IL2ScrollMessenger.sendMessage` with the versioned envelope.

#### Message envelope format

Every withdrawal now carries a 2-byte envelope in the `message` field of the
L2-to-L1 send:

```text
byte 0: ENVELOPE_VERSION = 0x01
byte 1: flags            (0x00 = P2PKH, 0x01 = P2SH)
```

The amount and target address remain in the existing `sendMessage` parameters.
Any L1-side consumer that previously assumed an empty `message` must be updated
to parse this envelope.

#### New address-decoding library

New file: [`src/dogeos/DogeAddressLib.sol`](src/dogeos/DogeAddressLib.sol)

This pure Solidity library provides:

- `decode(string)`
- `decodeChecked(string, bytes1, bytes1)`

It performs Base58Check decoding, double-sha256 checksum verification, and
prefix matching. The library is inlined into `Moat`; it is not deployed as a
separate contract.

#### Constructor signature change

Before:

```solidity
constructor()
```

After:

```solidity
constructor(bytes1 _p2pkhPrefix, bytes1 _p2shPrefix)
```

`P2PKH_PREFIX` and `P2SH_PREFIX` are immutables. They are baked into the
implementation runtime bytecode and do not use proxy storage.

This means a new implementation contract must be deployed per network. The
implementation address can differ even when the proxy address is the same.

#### ABI changes

Additions to `IMoat`:

- `function P2PKH_PREFIX() external view returns (bytes1);`
- `function P2SH_PREFIX() external view returns (bytes1);`
- `function withdrawToP2PKH(address) external payable;`
- `function withdrawToP2SH(address) external payable;`
- `function withdrawToDogeAddress(string) external payable;`

Removed custom errors:

- `ErrorUnprovenL1Message()`
- `ErrorInvalidDataLength(uint256)`
- `Unauthorized()`

The removed errors are no longer thrown by `Moat`; `Unauthorized()` belongs to
`OwnableBase` and should not have been re-declared in `IMoat`.

### 2.2 Storage layout

The Moat contract layout is preserved and safe for proxy upgrade:

| Slot   | Field                                                                                                       |
| ------ | ----------------------------------------------------------------------------------------------------------- |
| `0x00` | `_owner` from `OwnableBase`                                                                                 |
| `0x01` | `_status` plus `_initialized` / `_initializing` packing from `ReentrancyGuardUpgradeable` / `Initializable` |
| `...`  | `messenger`, `basculeVerifier`, `withdrawalFee`, `minWithdrawalAmount`, `feeRecipient`, `depositFee`        |

`P2PKH_PREFIX` and `P2SH_PREFIX` live in bytecode as immutables and consume no
storage slots. No storage migration is required.

No `initialize` re-run is required because the proxy is already initialized.

### 2.3 Upgrade model

#### Fresh genesis

[`scripts/deterministic/DeployScroll.s.sol`](scripts/deterministic/DeployScroll.s.sol)
handles this automatically in `deployL2Moat()`:

1. Selects prefixes via `_dogePrefixesFromL1ChainId()` based on `CHAIN_ID_L1`.
2. Encodes them into the implementation constructor args.
3. Deploys the new implementation.
4. Calls `upgrade()` on `L2_PROXY_ADMIN`.

#### Live chain

Moat is a `TransparentUpgradeableProxy` owned by `L2_PROXY_ADMIN_ADDR`. The
upgrade is a normal ProxyAdmin implementation swap.

No hard fork, geth change, or node coordination is required.

### 2.4 Script behavior

#### `deploy-moat-impl.sh`

[`scripts/deterministic/shell/deploy-moat-impl.sh`](scripts/deterministic/shell/deploy-moat-impl.sh)
calls `DeployScroll.deployL2MoatImpl("L2", "write-config")` via `forge script`.

It:

- sets `FOUNDRY_EVM_VERSION=cancun`;
- sets `FOUNDRY_BYTECODE_HASH=none`;
- reads `EXTERNAL_RPC_URI_L2` from `volume/config.toml`;
- reads `L2_PROXY_ADMIN_ADDR` and `L2_MOAT_PROXY_ADDR` from `volume/config-contracts.toml`;
- auto-selects Dogecoin prefixes from `CHAIN_ID_L1`;
- checks config files, required commands, supported `CHAIN_ID_L1`, ProxyAdmin code, proxy code, and the current implementation;
- runs preflight and simulation only by default;
- always runs one simulation first;
- with `BROADCAST=1`, runs a second call with `--broadcast`;
- writes `L2_MOAT_IMPLEMENTATION_ADDR` to `volume/config-contracts.toml` in `write-config` mode;
- prints exact `upgrade(address,address)` calldata for the ProxyAdmin owner.

#### `submit-moat-proxy-upgrade.sh`

[`scripts/deterministic/shell/submit-moat-proxy-upgrade.sh`](scripts/deterministic/shell/submit-moat-proxy-upgrade.sh)
submits the ProxyAdmin upgrade transaction.

It:

- reads `L2_PROXY_ADMIN_ADDR`, `L2_MOAT_PROXY_ADDR`, and `L2_MOAT_IMPLEMENTATION_ADDR` from `volume/config-contracts.toml`;
- reads `EXTERNAL_RPC_URI_L2` from `volume/config.toml`;
- checks config files, required commands, ProxyAdmin code, proxy code, and target implementation code;
- warns if the target implementation is already active;
- prints `ProxyAdmin owner`;
- prints `impl before`;
- prints the pre-upgrade storage snapshot;
- prints `impl after` for confirmation;
- runs preflight only by default;
- sends `cast send upgrade()` only when `BROADCAST=1`;
- uses `--legacy` for the transaction.

### 2.5 External services

| Service            | Required action                                                                                                                                                                                       | Severity                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| withdraw processor | Parse the new 2-byte envelope from the `message` field of every L2-to-L1 send. `flags & 0x01` selects P2SH vs P2PKH when constructing the Dogecoin output script. Reject unexpected `version` values. | Breaking; must ship before upgrade |
| Frontend / SDK     | Expose the three typed entry points. Keep `withdrawToL1` as a P2PKH alias for legacy callers.                                                                                                         | Additive                           |
| Bascule verifier   | No change. `handleL1Message` is untouched by this upgrade.                                                                                                                                            | None                               |

Deploy the envelope-aware relayer before the proxy upgrade. After the proxy is
upgraded, even `withdrawToL1` emits a `version=1, flags=0` envelope. A relayer
that only accepts an empty `message` will drop every withdrawal.

### 2.6 Rollback behavior

Rollback is another `ProxyAdmin.upgrade()` call pointing to the previous
implementation.

Caveats:

- Any withdrawals queued between the forward upgrade and rollback carry
  `version=1` envelopes.
- The pre-upgrade relayer must be able to process or safely park those envelope
  withdrawals.
- Do not roll back the relayer unless you are certain no envelope withdrawals
  are in flight.
- Storage is preserved across both directions.
- If rollback is permanent, the P2SH entry points disappear from the ABI, so
  SDKs and frontends must revert to the old interface.

---

## 3. References

- Contract source: [`src/dogeos/Moat.sol`](src/dogeos/Moat.sol)
- Interface: [`src/dogeos/IMoat.sol`](src/dogeos/IMoat.sol)
- Address decoder: [`src/dogeos/DogeAddressLib.sol`](src/dogeos/DogeAddressLib.sol)
- Deploy script: [`scripts/deterministic/DeployScroll.s.sol`](scripts/deterministic/DeployScroll.s.sol) (`deployL2Moat`, `deployL2MoatImpl`, `_dogePrefixesFromL1ChainId`)
- Deploy impl shell script: [`scripts/deterministic/shell/deploy-moat-impl.sh`](scripts/deterministic/shell/deploy-moat-impl.sh)
- Upgrade proxy shell script: [`scripts/deterministic/shell/submit-moat-proxy-upgrade.sh`](scripts/deterministic/shell/submit-moat-proxy-upgrade.sh)
- Tests: [`src/test/dogeos/Moat.t.sol`](src/test/dogeos/Moat.t.sol)
- Merge commit: `3e29ab0` (`feat/p2sh-withdrawals` to `dogeos-v0.3.0-develop`)
- Source commit: `4cfcad9 feat(moat): add P2SH withdrawal support with message envelope encoding`
