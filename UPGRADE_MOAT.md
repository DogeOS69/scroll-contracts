# Moat Upgrade - v0.3.0 Withdrawal Bridge (P2SH + Satoshi Flooring + Fee Vault Routing)

This document is split into two parts:

- **Operations:** commands and checks an operator should run.
- **Explanation:** why the upgrade is needed and how it works.

This is the consolidated v0.3.0 withdrawal-bridge upgrade for networks running
v0.2.0. It covers, in one upgrade window:

1. **P2SH withdrawal support** — typed entry points, a versioned 2-byte message
   envelope, and on-chain Base58Check address decoding
   (`feat/p2sh-withdrawals`).
2. **Satoshi flooring** — withdrawal amounts are floored to a multiple of
   `1e10` wei (1 Dogecoin satoshi) so every L2->L1 value is exactly
   representable as a Dogecoin UTXO output; sub-satoshi dust joins the fee
   (`fix/floor-withdrawal-amounts`, PR #38).
3. **Fee vault routing** — `L2TxFeeVault` withdrawals are routed through the
   new `FeeVaultMoatAdapter` (fee-exempt via `Moat.setFeeExempt`), and the
   `FEE_VAULT` exemption is removed from `L2DogeOsMessenger`, making the Moat
   the only possible L2->L1 sender (same PR).

No predeploy bytecode changes: the fee vault keeps its v0.2.0 code and is
reconfigured purely through its owner setters. The only implementation swaps
are the two proxied contracts (`Moat`, `L2DogeOsMessenger`); the adapter is a
fresh standalone deployment.

Reference merges: [`3e29ab0`](../../commit/3e29ab0) (`feat/p2sh-withdrawals`,
introduced by [`4cfcad9`](../../commit/4cfcad9)) and PR #38
(`fix/floor-withdrawal-amounts`).

---

## 1. Operations

Use this section during the actual upgrade. It intentionally focuses on what to
run and what to verify.

### 1.1 Operational summary

The live-chain upgrade has seven possible chain-changing actions, **in this
order**:

| #   | Action                                                     | Signer                   | Script                                                                                                   |
| --- | ---------------------------------------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------- |
| 1   | Configure Galileo `L1GasPriceOracle` static fee parameters | `L1GasPriceOracle owner` | `OWNER_PRIVATE_KEY=... BROADCAST=1 scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh`     |
| 2   | Deploy the new `Moat` implementation                       | `DEPLOYER`               | `BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh`                                            |
| 3   | Point the `Moat` proxy to the new implementation           | `ProxyAdmin owner`       | `OWNER_PRIVATE_KEY=... BROADCAST=1 scripts/deterministic/shell/submit-moat-proxy-upgrade.sh`             |
| 4   | Deploy the `FeeVaultMoatAdapter`                           | `DEPLOYER`               | `BROADCAST=1 scripts/deterministic/shell/deploy-fee-vault-moat-adapter.sh`                               |
| 5   | Rewire the fee vault through the adapter (4 owner calls)   | `Moat + fee vault owner` | `OWNER_PRIVATE_KEY=... BROADCAST=1 scripts/deterministic/shell/submit-fee-vault-rewire.sh`               |
| 6   | Deploy the new `L2DogeOsMessenger` implementation          | `DEPLOYER`               | `BROADCAST=1 scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh`                                |
| 7   | Point the messenger proxy to the new implementation        | `ProxyAdmin owner`       | `OWNER_PRIVATE_KEY=... BROADCAST=1 scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh` |

The ordering is load-bearing and fail-closed:

- Step 1 is idempotent and independent of the Moat implementation swap. It
  must be run or explicitly verified so Galileo L1 data fees use
  `commitScalar`, `blobScalar`, and `penaltyFactor` from config.
- Step 3 before step 5: the rewire calls `Moat.setFeeExempt`, which only exists
  on the new implementation.
- Step 5 before step 7: after the messenger upgrade, only the Moat can send
  L2->L1 messages — a vault still pointing directly at the messenger would have
  its withdrawals revert (fees accumulate, nothing is lost, but withdrawals
  stall until rewired). `submit-dogeos-messenger-proxy-upgrade.sh` refuses to
  broadcast while the vault is unrewired.
- Stopping after any step leaves the bridge in a working state.

The other steps are configuration selection, dry runs, preflight checks, and
post-upgrade verification. They are included to avoid upgrading the wrong
network, proxy, or implementation.

Current deterministic scripts do not support an environment-variable-only
configuration. Network values and contract addresses are read from:

- `volume/config.toml`
- `volume/config-contracts.toml`

**New config prerequisites:** `volume/config.toml` is copied from the target
network configuration repository, so add these values to that repository before
starting. Otherwise the local `volume/config.toml` copy will be overwritten the
next time an operator prepares an upgrade workspace.

Under `[contracts]`, define:

```toml
# Galileo L1GasPriceOracle static parameters. These are the architect-approved
# Galileo v2 defaults, matching Scroll mainnet reference values at block 34228520.
COMMIT_SCALAR = 38_720_000_000
BLOB_SCALAR = 8_000_000_000
PENALTY_FACTOR = 10_000

# Deprecated pre-Curie/pre-Galileo scalar. Keep for legacy formula branches.
SCALAR = 938_846

# Dogecoin P2PKH hash160 (20 bytes, encoded as an EVM address) that receives
# fee vault withdrawals.
FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x..."
```

`submit-l1-gas-price-oracle-config.sh` refuses to run without
`COMMIT_SCALAR`, `BLOB_SCALAR`, and `PENALTY_FACTOR`. The rewire script refuses
to run without `FEE_VAULT_DOGE_RECIPIENT_ADDR`.

Private keys are the intended environment-variable inputs. For this upgrade,
`DEPLOYER_PRIVATE_KEY` is used by the implementation deploy steps, and
`OWNER_PRIVATE_KEY` is used by the L1GasPriceOracle owner config step, the
ProxyAdmin upgrade steps, and the rewire step (the Moat, fee vault, and
ProxyAdmin are expected to share one owner; the scripts print the actual owners
during preflight).

This runbook prepares `volume` as a local working copy of the target network
configuration. The deploy steps write `L2_MOAT_IMPLEMENTATION_ADDR`,
`L2_FEE_VAULT_MOAT_ADAPTER_ADDR`, and `L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR`
back to `volume/config-contracts.toml`, so treat `volume` as the active config
workspace for this upgrade run and sync it back to the network configuration
repository afterwards.

### 1.2 Command quick start

Run from the `scroll-contracts` repository root. Replace
`/path/to/dogeos-aws-testnet` with the real target network configuration
repository path.

```bash
CONFIG_DIR=/path/to/dogeos-aws-testnet

cd /path/to/scroll-contracts
git fetch origin
git switch dogeos-v0.3.0-develop
git pull --ff-only origin dogeos-v0.3.0-develop

mkdir -p volume
cp "$CONFIG_DIR/config.toml" volume/config.toml
cp "$CONFIG_DIR/config-contracts.toml" volume/config-contracts.toml
perl -pi -e 's/testnet\.dogeos\.com/devnet.doge.xyz/g' volume/config.toml

# Confirm these [contracts] values exist in the target network config before
# continuing. Add them to $CONFIG_DIR/config.toml, then recopy if they are
# missing from volume/config.toml:
#   COMMIT_SCALAR = 38_720_000_000
#   BLOB_SCALAR = 8_000_000_000
#   SCALAR = 938_846
#   PENALTY_FACTOR = 10_000
#   FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x..."
for key in COMMIT_SCALAR BLOB_SCALAR SCALAR PENALTY_FACTOR FEE_VAULT_DOGE_RECIPIENT_ADDR; do
  if ! grep -q "^$key[[:space:]]*=" volume/config.toml; then
    echo "ERROR: $key is missing from volume/config.toml" >&2
    exit 1
  fi
done

# Confirm that dogeos.com no longer appears in volume/config.toml before running deploy scripts.
if grep -n 'dogeos\.com' volume/config.toml; then
  echo "ERROR: dogeos.com still appears in volume/config.toml" >&2
  exit 1
fi

# 1: Galileo L1GasPriceOracle static fee parameters
scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh

# 2+3: Moat implementation + proxy upgrade
scripts/deterministic/shell/deploy-moat-impl.sh
BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh

scripts/deterministic/shell/submit-moat-proxy-upgrade.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-moat-proxy-upgrade.sh

# 4: FeeVaultMoatAdapter
scripts/deterministic/shell/deploy-fee-vault-moat-adapter.sh
BROADCAST=1 scripts/deterministic/shell/deploy-fee-vault-moat-adapter.sh

# 5: rewire fee vault (setFeeExempt -> updateRecipient -> updateMinWithdrawAmount -> updateMessenger)
scripts/deterministic/shell/submit-fee-vault-rewire.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-fee-vault-rewire.sh

# 6+7: messenger implementation + proxy upgrade (refuses to run before step 5)
scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh
BROADCAST=1 scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh

scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh

```

### 1.3 Operator checklist

Before sending any transaction:

- Check out the branch that contains this upgrade.
- Copy the target network `config.toml` and `config-contracts.toml` into
  `<repo-root>/volume`.
- After copying `config.toml`, replace `testnet.dogeos.com` with
  `devnet.doge.xyz`.
- Add `COMMIT_SCALAR`, `BLOB_SCALAR`, `PENALTY_FACTOR`, and the legacy
  `SCALAR` value to `volume/config.toml` under `[contracts]` and to the
  network configuration repository. `COMMIT_SCALAR` is the Galileo value used
  by `L1GasPriceOracle.getL1Fee(bytes)`; `SCALAR` is deprecated and does not
  affect Galileo sizing.
- Add `FEE_VAULT_DOGE_RECIPIENT_ADDR` to `volume/config.toml` under
  `[contracts]` (the Dogecoin P2PKH hash160 for fee withdrawals) and to the
  network configuration repository.
- Confirm the envelope-aware withdraw processor is already deployed, and that
  it floors / expects satoshi-aligned amounts consistently with the contract.
- Confirm you control the `L1GasPriceOracle owner`, `ProxyAdmin owner`, and the
  Moat / fee vault owner keys printed by the upgrade scripts.
- Run the dry-run commands first, then run the same flow with `BROADCAST=1`.
- Follow the step order from 1.1 — the scripts enforce the critical ordering,
  but do not skip ahead.

### 1.4 Existing deployment

Run all commands from the repository root unless noted otherwise.

#### Step 1 - Prepare local `volume` config

Config preparation commands:

```bash
CONFIG_DIR=/path/to/dogeos-aws-testnet

if [ -L volume ]; then unlink volume; fi
mkdir -p volume
cp "$CONFIG_DIR/config.toml" volume/config.toml
cp "$CONFIG_DIR/config-contracts.toml" volume/config-contracts.toml
perl -pi -e 's/testnet\.dogeos\.com/devnet.doge.xyz/g' volume/config.toml
ls -l volume/config.toml volume/config-contracts.toml
```

Expected shape:

```text
volume/config.toml
volume/config-contracts.toml
```

The scripts read:

- `volume/config.toml`
- `volume/config-contracts.toml`

Use the real path to the target network configuration repository as
`CONFIG_DIR`. If `volume` is currently a symlink from a previous run, remove
only the symlink before creating the local `volume` directory. After copying
`config.toml`, replace `testnet.dogeos.com` with `devnet.doge.xyz` so the
upgrade scripts use the expected RPC host.

Before continuing, confirm the copied `volume/config.toml` contains these
`[contracts]` keys. If not, add them to the source network configuration
repository, then copy `config.toml` again:

```toml
COMMIT_SCALAR = 38_720_000_000
BLOB_SCALAR = 8_000_000_000
SCALAR = 938_846
PENALTY_FACTOR = 10_000
FEE_VAULT_DOGE_RECIPIENT_ADDR = "0x..."
```

`COMMIT_SCALAR` is the Galileo `commitScalar` slot. Do not rely on `SCALAR` for
Galileo sizing; `SCALAR` is retained only for legacy formula branches. The
Galileo defaults above are copied from the latest architecture guidance:
Scroll mainnet block 34228520 had `commitScalar = 38720000000`,
`blobScalar = 8000000000`, and `penaltyFactor = 10000`.

#### Step 2 - Dry-run L1GasPriceOracle static fee parameter config

```bash
scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh
```

Check the printed values before continuing:

- `L1GasPriceOracle owner`
- current `commitScalar`, `blobScalar`, `penaltyFactor`
- target `COMMIT_SCALAR`, `BLOB_SCALAR`, `PENALTY_FACTOR` from
  `volume/config.toml`

This step intentionally does not set `l1BaseFee` or `l1BlobBaseFee`; those are
dynamic values updated by the whitelisted `fee_oracle` signer.

#### Step 3 - Broadcast L1GasPriceOracle static fee parameter config

Use the private key for the `L1GasPriceOracle owner`.

```bash
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh
```

The script performs three owner calls, skipping values that are already in the
desired state:

1. `L1GasPriceOracle.setCommitScalar(COMMIT_SCALAR)`
2. `L1GasPriceOracle.setBlobScalar(BLOB_SCALAR)`
3. `L1GasPriceOracle.setPenaltyFactor(PENALTY_FACTOR)`

#### Step 4 - Dry-run implementation deployment

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

#### Step 5 - Broadcast implementation deployment

```bash
BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh
```

After this succeeds, confirm `volume/config-contracts.toml` contains the new:

```toml
L2_MOAT_IMPLEMENTATION_ADDR = "..."
```

#### Step 6 - Dry-run ProxyAdmin upgrade

```bash
scripts/deterministic/shell/submit-moat-proxy-upgrade.sh
```

Check the printed values before continuing:

- `ProxyAdmin owner`
- implementation before upgrade
- target implementation
- pre-upgrade storage snapshot: `messenger`, `withdrawalFee`,
  `minWithdrawalAmount`, `depositFee`, `feeRecipient`, `owner`

The target implementation must already have bytecode on-chain.

#### Step 7 - Broadcast ProxyAdmin upgrade

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

#### Step 8 - Deploy the FeeVaultMoatAdapter

```bash
scripts/deterministic/shell/deploy-fee-vault-moat-adapter.sh
BROADCAST=1 scripts/deterministic/shell/deploy-fee-vault-moat-adapter.sh
```

The adapter is a small immutable contract: `FeeVaultMoatAdapter(feeVault, moatProxy)`.
After broadcast, confirm `volume/config-contracts.toml` contains the new:

```toml
L2_FEE_VAULT_MOAT_ADAPTER_ADDR = "..."
```

The deploy script warns (but does not fail) if `FEE_VAULT_DOGE_RECIPIENT_ADDR`
is still missing from `volume/config.toml` — fix that before the next step.

#### Step 9 - Rewire the fee vault through the adapter

```bash
scripts/deterministic/shell/submit-fee-vault-rewire.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-fee-vault-rewire.sh
```

The script performs four owner calls, in order, skipping any that are already
in the desired state (safe to rerun):

1. `Moat.setFeeExempt(adapter, true)` — fee vault withdrawals pay no base
   withdrawal fee (only sub-satoshi dust goes to the Moat `feeRecipient`).
2. `L2TxFeeVault.updateRecipient(FEE_VAULT_DOGE_RECIPIENT_ADDR)` — the vault's
   recipient is reinterpreted by the adapter as the Dogecoin P2PKH hash160; the
   old EVM-style recipient must not be left in place.
3. `L2TxFeeVault.updateMinWithdrawAmount(moat.minWithdrawalAmount() + moat.SATOSHI_TO_WEI())`
   — guarantees a balance passing the vault's own minimum cannot revert inside
   the Moat. Re-run this step whenever the Moat minimum is raised.
4. `L2TxFeeVault.updateMessenger(adapter)` — from this point fee vault
   withdrawals are standard Moat withdrawals.

Preflight refuses to run if the Moat proxy does not yet expose
`SATOSHI_TO_WEI()` (i.e. summary steps 2-3 have not landed) or if the
adapter's immutables do not match the configured vault and Moat proxy.

#### Step 10 - Deploy the L2DogeOsMessenger implementation

```bash
scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh
BROADCAST=1 scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh
```

Constructor args are read from `volume/config-contracts.toml`
(`L1_SCROLL_MESSENGER_PROXY_ADDR`, `L2_MESSAGE_QUEUE_ADDR`,
`L2_MOAT_PROXY_ADDR`) — the fee vault is no longer a constructor argument.
After broadcast, confirm `volume/config-contracts.toml` contains the new:

```toml
L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR = "..."
```

#### Step 11 - Upgrade the messenger proxy

```bash
scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh
```

After this transaction the Moat is the only address that can send L2->L1
messages. The script refuses to broadcast while
`L2TxFeeVault.messenger() != L2_FEE_VAULT_MOAT_ADAPTER_ADDR` (override with
`FORCE=1` only if you intentionally accept stalled fee withdrawals).

#### Step 12 - Verify the upgrade

Set the RPC URL used for direct `cast` checks:

```bash
export L2_RPC=<L2_RPC>
```

Check the Galileo L1 data fee parameters:

```bash
cast call <L1_GAS_PRICE_ORACLE_ADDR> 'commitScalar()(uint256)'  --rpc-url "$L2_RPC"
cast call <L1_GAS_PRICE_ORACLE_ADDR> 'blobScalar()(uint256)'    --rpc-url "$L2_RPC"
cast call <L1_GAS_PRICE_ORACLE_ADDR> 'penaltyFactor()(uint256)' --rpc-url "$L2_RPC"
```

Expected values are the `COMMIT_SCALAR`, `BLOB_SCALAR`, and `PENALTY_FACTOR`
values in `volume/config.toml`. Do not use `scalar()` for this check; `scalar`
is the deprecated pre-Curie/pre-Galileo field and is not read by the Galileo
formula.

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

Compare these values with the pre-upgrade snapshot printed in Step 6.

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

Check the flooring constant and fee exemption:

```bash
cast call <L2_MOAT_PROXY_ADDR> 'SATOSHI_TO_WEI()(uint256)' --rpc-url "$L2_RPC"
# expected: 10000000000

cast call <L2_MOAT_PROXY_ADDR> 'feeExemptCallers(address)(bool)' \
  <L2_FEE_VAULT_MOAT_ADAPTER_ADDR> --rpc-url "$L2_RPC"
# expected: true
```

Check the fee vault rewire:

```bash
cast call <L2_TX_FEE_VAULT_ADDR> 'messenger()(address)' --rpc-url "$L2_RPC"
# expected: <L2_FEE_VAULT_MOAT_ADAPTER_ADDR>

cast call <L2_TX_FEE_VAULT_ADDR> 'recipient()(address)' --rpc-url "$L2_RPC"
# expected: <FEE_VAULT_DOGE_RECIPIENT_ADDR> (the doge hash160, not an EVM wallet)

cast call <L2_TX_FEE_VAULT_ADDR> 'minWithdrawAmount()(uint256)' --rpc-url "$L2_RPC"
# expected: >= moat.minWithdrawalAmount() + 1e10
```

Check that the messenger rejects non-Moat senders (the fee vault path):

```bash
cast call <L2_DOGEOS_MESSENGER_PROXY_ADDR> \
  'sendMessage(address,uint256,bytes,uint256)' \
  0x0000000000000000000000000000000000000001 0 0x 0 \
  --from <L2_TX_FEE_VAULT_ADDR> --rpc-url "$L2_RPC"
# expected: revert ErrorSenderNotMoat
```

Finally, send end-to-end withdrawals and confirm the L1 side handles them
correctly:

- `withdrawToP2PKH`, `withdrawToP2SH`, `withdrawToDogeAddress` — including one
  with a **sub-satoshi dust amount** (e.g. value ending in `...123` wei):
  confirm the `WithdrawalQueued` amount is a multiple of `1e10` wei, the dust
  landed with the fee recipient, and the Dogecoin UTXO matches the floored
  amount exactly.
- One fee vault withdrawal (`L2TxFeeVault.withdraw()` once the balance exceeds
  its minimum): confirm the resulting L2->L1 message is sent **by the Moat**
  with a `version=1, flags=0` envelope, the value is satoshi-aligned, and no
  base withdrawal fee was deducted.

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

1. Compute the effective fee (zero for fee-exempt callers, see below).
2. Floor the post-fee amount to a multiple of `SATOSHI_TO_WEI` (`1e10` wei);
   the sub-satoshi remainder is added to the fee.
3. Validate the floored amount against the minimum (and against zero).
4. Transfer the fee (base fee + dust) to `feeRecipient`.
5. Call `IL2ScrollMessenger.sendMessage` with the versioned envelope.

Invariants: `amount + fee == msg.value` and `amount % 1e10 == 0` in every
branch, so the Dogecoin UTXO output value always identifies the L2 withdrawal
exactly.

#### Satoshi flooring

The L2 native token has 18 decimals; Dogecoin has 8. The Doge-side withdraw
processor maps a UTXO output back to its originating L2 transaction using only
what it sees on Dogecoin, so the queued value must be exactly representable in
8 decimals. Any withdrawal value with sub-satoshi precision is floored and the
dust joins the fee. A withdrawal that floors to zero reverts.

#### Fee vault routing and fee exemption

`L2TxFeeVault.withdraw()` used to send value L2->L1 directly through the
messenger (`from = vault`, empty message, arbitrary precision) — invisible to a
processor that assumes all withdrawals come from the Moat. v0.3.0 routes it
through the new [`FeeVaultMoatAdapter`](src/dogeos/FeeVaultMoatAdapter.sol):
the vault's owner-settable `messenger` points at the adapter, which forwards
the value into `Moat.withdrawToP2PKH`, reinterpreting the vault's `recipient`
as the Dogecoin P2PKH hash160. Fee vault withdrawals therefore become standard
Moat withdrawals.

The new `Moat.setFeeExempt(address,bool)` (owner-only) exempts the adapter from
the base withdrawal fee so the protocol does not pay its own fee; flooring and
the minimum still apply.

#### Messenger sender restriction

`L2DogeOsMessenger` drops the `FEE_VAULT` constructor argument and sender
exemption: `_sendMessage` now requires `msg.sender == MOAT` **and** that the
message is exactly a valid v1 envelope (`0x0100` for P2PKH, `0x0101` for P2SH;
shared `WithdrawalEnvelope` library, so producer and enforcer cannot drift).
Every L2->L1 message on the network is a Moat withdrawal with a v1 envelope and
a satoshi-aligned value — enforced on-chain, not by convention. Legacy blank
messages are rejected outright: there is exactly ONE message representation per
Dogecoin recipient type, so the message bytes (and the message hash) are
deterministically reconstructable from the Dogecoin address used in the
withdrawal alone.

#### Message envelope format

Every withdrawal now carries a 2-byte envelope in the `message` field of the
L2-to-L1 send:

```text
byte 0: ENVELOPE_VERSION = 0x01
byte 1: flags            (0x00 = P2PKH, 0x01 = P2SH)
```

The amount and target address remain in the existing `sendMessage` parameters.
Any L1-side consumer that previously assumed an empty `message` must be updated
to parse this envelope. After the upgrade the messenger rejects non-envelope
messages (`ErrorInvalidWithdrawalEnvelope`), so no NEW empty-message
withdrawal can exist and the envelope is uniquely determined by the
recipient's address type. How consumers treat pre-upgrade empty-message
history, and when legacy handling is retired, is deliberately left open — it
will be settled alongside the hardfork / protocol-version-bump mechanics.

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
- `function SATOSHI_TO_WEI() external view returns (uint256);`
- `function feeExemptCallers(address) external view returns (bool);`
- `function setFeeExempt(address, bool) external;`
- `function withdrawToP2PKH(address) external payable;`
- `function withdrawToP2SH(address) external payable;`
- `function withdrawToDogeAddress(string) external payable;`
- `event FeeExemptionUpdated(address indexed account, bool exempt);`

`L2DogeOsMessenger` removals: the `FEE_VAULT()` getter and the fee vault
constructor argument.

`IMoat` removals:

- `function basculeVerifier() external view returns (address);`
- `function setBascule(address) external;`
- `event BasculeVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);`

Removed custom errors:

- `ErrorUnprovenL1Message()`
- `ErrorInvalidDataLength(uint256)`
- `Unauthorized()`

The removed errors are no longer thrown by `Moat`; `Unauthorized()` belongs to
`OwnableBase` and should not have been re-declared in `IMoat`.

### 2.2 Storage layout

The Moat contract layout is preserved and safe for proxy upgrade:

| Slot          | Field                                                                                                       |
| ------------- | ----------------------------------------------------------------------------------------------------------- |
| `0x00`        | `_owner` from `OwnableBase` packed with `_initialized` / `_initializing` from `Initializable`               |
| `0x01`        | `_status` from `ReentrancyGuardUpgradeable`                                                                 |
| `0x02`-`0x32` | `__gap` from `ReentrancyGuardUpgradeable`                                                                   |
| `0x33`-`0x38` | `messenger`, deprecated verifier slot, `withdrawalFee`, `minWithdrawalAmount`, `feeRecipient`, `depositFee` |
| `0x39` (57)   | **new in v0.3.0:** `feeExemptCallers` mapping — appended after the previously-last variable                 |

`P2PKH_PREFIX`, `P2SH_PREFIX`, and `SATOSHI_TO_WEI` live in bytecode as
immutables/constants and consume no storage slots. The only layout change is
the appended mapping, so no storage migration is required.

No `initialize` re-run is required because the proxy is already initialized.

### 2.3 Upgrade model

Moat is a `TransparentUpgradeableProxy` owned by `L2_PROXY_ADMIN_ADDR`. The
upgrade is a normal ProxyAdmin implementation swap.

No hard fork, geth change, or node coordination is required.

### 2.4 Script behavior

#### `submit-l1-gas-price-oracle-config.sh`

[`scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh`](scripts/deterministic/shell/submit-l1-gas-price-oracle-config.sh)
configures owner-managed Galileo L1 data fee parameters on
`L1GasPriceOracle`.

It:

- reads `EXTERNAL_RPC_URI_L2`, `COMMIT_SCALAR`, `BLOB_SCALAR`, and
  `PENALTY_FACTOR` from `volume/config.toml`;
- reads `L1_GAS_PRICE_ORACLE_ADDR` from `volume/config-contracts.toml`;
- fails if `COMMIT_SCALAR`, `BLOB_SCALAR`, or `PENALTY_FACTOR` is missing or
  zero;
- checks that `L1_GAS_PRICE_ORACLE_ADDR` has deployed code;
- prints `L1GasPriceOracle owner`;
- prints current and target `commitScalar`, `blobScalar`, and `penaltyFactor`;
- calls `SubmitL1GasPriceOracleConfig` via `forge script --broadcast` only
  when `BROADCAST=1`;
- skips any owner call whose current on-chain value already equals the target
  config value.

It does not set `l1BaseFee` or `l1BlobBaseFee`. Those are dynamic values set by
the whitelisted `fee_oracle` signer.

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
- calls `SubmitMoatProxyUpgrade` via `forge script --broadcast` only when
  `BROADCAST=1`;
- uses `--legacy` for the transaction.

### 2.5 External services

| Service             | Required action                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Severity                           |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| withdraw processor  | Parse the new 2-byte envelope from the `message` field of every L2-to-L1 send. `flags & 0x01` selects P2SH vs P2PKH when constructing the Dogecoin output script. Reject unexpected `version` values. After the messenger upgrade it can assume **every** L2->L1 message has `from = Moat`, a v1 envelope, and a satoshi-aligned value (the basis for UTXO -> L2 tx mapping) — enforced by the messenger, which rejects anything that is not exactly `0x0100`/`0x0101`. New messages are therefore deterministically reconstructable from the Dogecoin address type. (Treatment of pre-upgrade empty-message history is left open pending hardfork/protocol-version mechanics.) | Breaking; must ship before upgrade |
| Frontend / SDK      | Expose the three typed entry points. Keep `withdrawToL1` as a P2PKH alias for legacy callers. Surface the flooring: amounts below 1e10-wei precision are truncated into the fee.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Additive                           |
| Fee collection ops  | Fee vault withdrawals now land at the configured Dogecoin address (`FEE_VAULT_DOGE_RECIPIENT_ADDR`), not an L1 EVM wallet. Update treasury monitoring accordingly.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Breaking; coordinate with step 9   |
| L1 deposit handling | `handleL1Message` no longer calls a verifier hook; deposit messages are gated by the configured messenger and existing fee/target-call checks.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Breaking for verifier integrations |

Deploy the envelope-aware relayer before the proxy upgrade. After the proxy is
upgraded, even `withdrawToL1` emits a `version=1, flags=0` envelope, and the
messenger refuses anything else — no new blank-message withdrawal can be
created. A relayer that only accepts an empty `message` will drop every
withdrawal. The retirement timeline for legacy empty-message handling on the
consumer side is TBD pending the hardfork / protocol-version-bump plan.

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
- Storage is preserved across both directions (the appended
  `feeExemptCallers` slot is simply ignored by the old implementation).
- If rollback is permanent, the P2SH entry points disappear from the ABI, so
  SDKs and frontends must revert to the old interface.
- **Rolling back the Moat while the new messenger is live breaks ALL
  withdrawals**, not only fee withdrawals: the v0.2.0 Moat sends empty
  messages, which the new messenger rejects with
  `ErrorInvalidWithdrawalEnvelope` (and the adapter calls `withdrawToP2PKH`,
  which does not exist on the v0.2.0 implementation). Roll back in reverse
  order — messenger proxy first (restores the vault's direct-send permission
  and empty-message acceptance), then
  `vault.updateMessenger(<messenger proxy>)` and
  `vault.updateRecipient(<old EVM recipient>)`, then the Moat proxy.

---

## 3. References

- Contract source: [`src/dogeos/Moat.sol`](src/dogeos/Moat.sol)
- Interface: [`src/dogeos/IMoat.sol`](src/dogeos/IMoat.sol)
- Address decoder: [`src/dogeos/DogeAddressLib.sol`](src/dogeos/DogeAddressLib.sol)
- Fee vault adapter: [`src/dogeos/FeeVaultMoatAdapter.sol`](src/dogeos/FeeVaultMoatAdapter.sol)
- Messenger: [`src/dogeos/L2DogeOsMessenger.sol`](src/dogeos/L2DogeOsMessenger.sol)
- Deploy script: [`scripts/deterministic/DeployScroll.s.sol`](scripts/deterministic/DeployScroll.s.sol) (`deployL2MoatImpl`, `deployL2FeeVaultMoatAdapter`, `deployL2DogeOsMessengerImpl`, `_dogePrefixesFromL1ChainId`)
- Transaction scripts: [`scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol`](scripts/deterministic/SubmitL1GasPriceOracleConfig.s.sol), [`scripts/deterministic/SubmitProxyUpgrades.s.sol`](scripts/deterministic/SubmitProxyUpgrades.s.sol), [`scripts/deterministic/SubmitFeeVaultRewire.s.sol`](scripts/deterministic/SubmitFeeVaultRewire.s.sol)
- Shell scripts: [`scripts/deterministic/shell/`](scripts/deterministic/shell/) — `submit-l1-gas-price-oracle-config.sh`, `deploy-moat-impl.sh`, `submit-moat-proxy-upgrade.sh`, `deploy-fee-vault-moat-adapter.sh`, `submit-fee-vault-rewire.sh`, `deploy-dogeos-messenger-impl.sh`, `submit-dogeos-messenger-proxy-upgrade.sh`
- Tests: [`src/test/dogeos/Moat.t.sol`](src/test/dogeos/Moat.t.sol), [`src/test/dogeos/FeeVaultMoatAdapter.t.sol`](src/test/dogeos/FeeVaultMoatAdapter.t.sol), [`src/test/dogeos/L2DogeOsMessenger.t.sol`](src/test/dogeos/L2DogeOsMessenger.t.sol)
- Merge commit: `3e29ab0` (`feat/p2sh-withdrawals` to `dogeos-v0.3.0-develop`)
- Source commit: `4cfcad9 feat(moat): add P2SH withdrawal support with message envelope encoding`
- Flooring + fee vault routing: PR #38 (`fix/floor-withdrawal-amounts`)
