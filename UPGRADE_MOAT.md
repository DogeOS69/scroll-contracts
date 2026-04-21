# Moat Upgrade — P2SH Withdrawal Support

This document describes how to upgrade the L2 `Moat` contract (proxy address
`L2_MOAT_PROXY_ADDR`) to the `feat/p2sh-withdrawals` revision that adds P2SH
withdrawal support, a versioned message envelope, and on-chain Base58Check
address decoding.

Reference merge: [`3e29ab0`](../../commit/3e29ab0) (merges
`feat/p2sh-withdrawals` into `dogeos-v0.3.0-develop`, introduced by
[`4cfcad9`](../../commit/4cfcad9)).

---

## 1. What changes

### 1.1 New withdrawal entry points

| Function                        | Behavior                                                                                                                                                                 |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `withdrawToL1(address)`         | **Behavior change.** Still P2PKH, but now attaches a 2-byte envelope (flags=0) instead of empty bytes. Kept for backward compatibility; prefer the typed variants below. |
| `withdrawToP2PKH(address)`      | New. Semantic alias of `withdrawToL1` — payload is the 20-byte hash160 of the recipient's pubkey.                                                                        |
| `withdrawToP2SH(address)`       | New. Payload is the 20-byte hash160 of the redeem script; envelope flags=`0x01`.                                                                                         |
| `withdrawToDogeAddress(string)` | New. Accepts a full Base58Check-encoded Dogecoin address; the contract decodes it on-chain via `DogeAddressLib` and routes to P2PKH or P2SH based on the version byte.   |

All four go through a common `_processWithdrawal(target, isP2SH)` path: fee/min
checks, fee transfer, then `IL2ScrollMessenger.sendMessage` with the envelope.

### 1.2 Message envelope format

Every withdrawal now carries a 2-byte envelope as the `message` field of the
L2→L1 send:

```
byte 0: ENVELOPE_VERSION = 0x01
byte 1: flags            (0x00 = P2PKH, 0x01 = P2SH)
```

The amount and target address remain in the existing `sendMessage` parameters.
**Any L1-side consumer that previously assumed an empty `message` must be
updated** to parse this envelope.

### 1.3 New address-decoding library

New file: [`src/dogeos/DogeAddressLib.sol`](src/dogeos/DogeAddressLib.sol) — a
`library` with pure `decode(string)` and `decodeChecked(string, bytes1, bytes1)`
functions. It performs Base58Check decoding, double-sha256 checksum verification,
and prefix matching. Inlined into `Moat`, not deployed as a separate contract.

### 1.4 Constructor signature change (breaking)

```solidity
// Before
constructor()

// After
constructor(bytes1 _p2pkhPrefix, bytes1 _p2shPrefix)
```

`P2PKH_PREFIX` / `P2SH_PREFIX` are **immutables**, baked into runtime bytecode,
not storage. The correct values per network (from `DeployScroll.s.sol`):

| Network (L1 chainId)  | P2PKH prefix | P2SH prefix |
| --------------------- | ------------ | ----------- |
| Mainnet (`1`)         | `0x1e`       | `0x16`      |
| Testnet (`111_111`)   | `0x71`       | `0xc4`      |
| Regtest (`5_555_555`) | `0x6f`       | `0xc4`      |

A new implementation contract must be deployed **per network** — the
implementation address will differ even if the proxy address is the same.

### 1.5 ABI changes (interface)

Additions to `IMoat`:

- `function P2PKH_PREFIX() external view returns (bytes1);`
- `function P2SH_PREFIX() external view returns (bytes1);`
- `function withdrawToP2PKH(address) external payable;`
- `function withdrawToP2SH(address) external payable;`
- `function withdrawToDogeAddress(string) external payable;`

Removed custom errors (no longer thrown, interface cleanup):

- `ErrorUnprovenL1Message()`
- `ErrorInvalidDataLength(uint256)`
- `Unauthorized()` (belongs to `OwnableBase`, shouldn't have been re-declared)

### 1.6 Storage layout — unchanged

The Moat contract layout is **preserved**; this is safe for proxy upgrade:

| Slot   | Field                                                                                                    |
| ------ | -------------------------------------------------------------------------------------------------------- |
| `0x00` | `_owner` (from `OwnableBase`)                                                                            |
| `0x01` | `_status` + `_initialized`/`_initializing` packing (from `ReentrancyGuardUpgradeable` / `Initializable`) |
| ...    | `messenger`, `basculeVerifier`, `withdrawalFee`, `minWithdrawalAmount`, `feeRecipient`, `depositFee`     |

`P2PKH_PREFIX` / `P2SH_PREFIX` live in **bytecode** (immutables) and consume no
storage slots. No storage migration is required.

---

## 2. Upgrade paths

### Path A — Fresh genesis (new chain)

Handled automatically by [`scripts/deterministic/DeployScroll.s.sol`](scripts/deterministic/DeployScroll.s.sol).
`deployL2Moat()` now:

1. Selects prefixes via `_dogePrefixesFromL1ChainId()` based on `CHAIN_ID_L1`.
2. Encodes them into the implementation's constructor args.
3. Deploys the new implementation, then calls `upgrade()` on `L2_PROXY_ADMIN`.

No additional manual steps — just run the usual deploy pipeline from this
branch.

Additionally, a standalone entry point `deployL2MoatImpl(string layer, string scriptMode)`
is available in `DeployScroll.s.sol` for deploying **only** the implementation
contract without running the full deploy flow. It reads the existing
`L2_PROXY_ADMIN_ADDR` and `L2_MOAT_PROXY_ADDR` from `volume/config-contracts.toml`,
deploys the new implementation, and logs the exact `upgrade()` calldata the
ProxyAdmin owner needs to submit. This is the entry point used by the shell
scripts in Path B below.

### Path B — Live chain (existing deployment)

Moat is a `TransparentUpgradeableProxy` owned by `L2_PROXY_ADMIN_ADDR`. The
upgrade is a normal ProxyAdmin call; **no hard fork, no geth change, no node
coordination required**.

#### B.1 Prerequisites

- **Setup the `volume` symlink**: The upgrade scripts read configuration and addresses from `volume/config.toml` and `volume/config-contracts.toml`. Symlink the target network's configuration directory to `volume` in the repository root:

  ```bash
  # run from repo root: ~/github/dogeos69/scroll-contracts
  # Example for devnet:
  ln -sfn ../dogeos-aws-devnet volume

  # verify
  ll volume
  # expected: volume -> ../dogeos-aws-devnet
  ```

- **Execution directory**: Scripts auto-detect repo root from their own path,
  so they can be executed from any current directory. The `volume` symlink must
  still exist at `<repo-root>/volume`.
- Run script preflight checks:
  ```bash
  # deploy script preflight + simulation
  scripts/deterministic/shell/deploy-moat-impl.sh
  ```
- Ensure you control the key that matches `ProxyAdmin owner` printed by
  `submit-moat-proxy-upgrade.sh`.
- Ensure the envelope-aware withdraw processor is already deployed (see §3)
  before executing the proxy upgrade transaction.

#### B.2 Deploy new implementation

Use the provided script [`deploy-moat-impl.sh`](scripts/deterministic/shell/deploy-moat-impl.sh):

```bash
# 1. Preflight/simulation only (default, no transaction)
scripts/deterministic/shell/deploy-moat-impl.sh

# 2. Broadcast deploy tx (script still simulates first)
BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh
```

The script calls `DeployScroll.deployL2MoatImpl("L2", "write-config")` via
`forge script`. It:

- sets `FOUNDRY_EVM_VERSION=cancun` and `FOUNDRY_BYTECODE_HASH=none`;
- reads `EXTERNAL_RPC_URI_L2` from `volume/config.toml` as L2 RPC;
- reads `L2_PROXY_ADMIN_ADDR` and `L2_MOAT_PROXY_ADDR` from
  `volume/config-contracts.toml`;
- auto-selects the Dogecoin prefixes from `CHAIN_ID_L1` in `volume/config.toml`;
- runs preflight checks (config files present, required commands installed,
  supported `CHAIN_ID_L1`, ProxyAdmin/proxy code exists, current impl query);
- runs preflight/simulation only by default;
- always runs one simulation first;
- when `BROADCAST=1`, runs a second call with `--broadcast` to actually deploy;
- writes `L2_MOAT_IMPLEMENTATION_ADDR` to `volume/config-contracts.toml` in
  `write-config` mode;
- prints the exact `upgrade(address,address)` calldata for the ProxyAdmin owner.

> **Important:** A simulation-only run can still refresh
> `L2_MOAT_IMPLEMENTATION_ADDR` in `volume/config-contracts.toml` (predicted
> deterministic address). Do not execute proxy upgrade until the broadcast
> deploy is done and the target implementation exists on-chain.

<details>
<summary>Manual fallback (without the script)</summary>

```bash
forge create src/dogeos/Moat.sol:Moat \
  --rpc-url <L2_RPC> \
  --private-key <DEPLOYER_KEY> \
  --constructor-args <P2PKH_PREFIX> <P2SH_PREFIX>
```

Where `<P2PKH_PREFIX>` / `<P2SH_PREFIX>` are the network-correct bytes from §1.4
(e.g. `0x1e` and `0x16` on mainnet). Record the returned
`L2_MOAT_IMPLEMENTATION_ADDR_NEW`.

</details>

#### B.3 Upgrade via ProxyAdmin

Use the provided script [`submit-moat-proxy-upgrade.sh`](scripts/deterministic/shell/submit-moat-proxy-upgrade.sh):

```bash
# 1. Preflight only (default, no transaction, no key required)
scripts/deterministic/shell/submit-moat-proxy-upgrade.sh

# 2. Broadcast upgrade tx (pass the ProxyAdmin owner key via env — never
#    hardcode it into the script file)
OWNER_PRIVATE_KEY=0x... BROADCAST=1 \
  scripts/deterministic/shell/submit-moat-proxy-upgrade.sh
```

Run this only after `BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh`
has succeeded; the script checks that `L2_MOAT_IMPLEMENTATION_ADDR` already has
deployed bytecode on-chain.

The script:

- reads `L2_PROXY_ADMIN_ADDR`, `L2_MOAT_PROXY_ADDR`, and
  `L2_MOAT_IMPLEMENTATION_ADDR` from `volume/config-contracts.toml` (updated by
  the deploy step);
- reads `EXTERNAL_RPC_URI_L2` from `volume/config.toml`;
- runs preflight checks (config files present, required commands installed,
  ProxyAdmin/proxy/target-impl code exists, and warns if target impl is already
  active);
- prints `ProxyAdmin owner`, `impl before`, and a pre-upgrade storage snapshot
  (`messenger`, `basculeVerifier`, `withdrawalFee`, `minWithdrawalAmount`,
  `depositFee`, `feeRecipient`, `owner`);
- prints impl-after for confirmation;
- runs preflight only by default;
- sends `cast send upgrade()` only when `BROADCAST=1` (uses `--legacy`).

> **⚠️ Safety:** By default the script does not send transactions. Verify all
> printed addresses/owner/snapshots first, then run with `BROADCAST=1`.

<details>
<summary>Manual fallback (without the script)</summary>

From the `L2_PROXY_ADMIN` owner:

```bash
cast send <L2_PROXY_ADMIN_ADDR> \
  'upgrade(address,address)' \
  <L2_MOAT_PROXY_ADDR> <L2_MOAT_IMPLEMENTATION_ADDR_NEW> \
  --rpc-url <L2_RPC> \
  --private-key <PROXY_ADMIN_OWNER_KEY> \
  --legacy
```

</details>

No `initialize` re-run — the contract is already initialized; the new
implementation reads existing storage, and immutables come from the new
bytecode.

#### B.4 Post-upgrade verification

```bash
# Implementation swapped
cast implementation <L2_MOAT_PROXY_ADDR> --rpc-url <L2_RPC>
# expect: L2_MOAT_IMPLEMENTATION_ADDR_NEW

# Immutables reflect the correct network
cast call <L2_MOAT_PROXY_ADDR> 'P2PKH_PREFIX()(bytes1)' --rpc-url <L2_RPC>
cast call <L2_MOAT_PROXY_ADDR> 'P2SH_PREFIX()(bytes1)'  --rpc-url <L2_RPC>

# Storage preserved — compare against §B.1 snapshot
cast call <L2_MOAT_PROXY_ADDR> 'messenger()(address)'           --rpc-url <L2_RPC>
cast call <L2_MOAT_PROXY_ADDR> 'withdrawalFee()(uint256)'       --rpc-url <L2_RPC>
cast call <L2_MOAT_PROXY_ADDR> 'minWithdrawalAmount()(uint256)' --rpc-url <L2_RPC>
cast call <L2_MOAT_PROXY_ADDR> 'owner()(address)'               --rpc-url <L2_RPC>

# New entry points exist (static call, expect revert with fee check — not 'function not found')
cast call <L2_MOAT_PROXY_ADDR> 'withdrawToP2SH(address)' 0x0000000000000000000000000000000000000001 --rpc-url <L2_RPC>
```

Also send one end-to-end withdrawal on each path (`withdrawToP2PKH`,
`withdrawToP2SH`, `withdrawToDogeAddress`) and confirm the L1-side relayer
picks up the envelope bytes correctly.

---

## 3. External services to coordinate

| Service            | Required action                                                                                                                                                                                                  | Severity                                |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| withdraw processor | ✅ **Parse the new 2-byte envelope** from the `message` field of every L2→L1 send. `flags & 0x01` selects P2SH-vs-P2PKH when constructing the Dogecoin output script. Reject messages with unexpected `version`. | **Breaking** — must ship before upgrade |
| Frontend / SDK     | Expose the three typed entry points; keep `withdrawToL1` as a P2PKH alias for legacy callers                                                                                                                     | Additive                                |
| Bascule verifier   | No change — `handleL1Message` path untouched by this upgrade                                                                                                                                                     | —                                       |

**Ordering:** deploy the envelope-aware relayer first (it must tolerate the new
`version=1, flags=0` envelope on P2PKH withdrawals), then execute the proxy
upgrade. Since `withdrawToL1` starts emitting envelopes immediately post-swap, a
relayer that only accepts empty `message` will drop every withdrawal.

---

## 4. Rollback

Rollback is straightforward — `ProxyAdmin.upgrade()` can point back at the
previous implementation address:

```bash
cast send <L2_PROXY_ADMIN_ADDR> \
  'upgrade(address,address)' \
  <L2_MOAT_PROXY_ADDR> <L2_MOAT_IMPLEMENTATION_ADDR_OLD> \
  --rpc-url <L2_RPC> \
  --private-key <PROXY_ADMIN_OWNER_KEY>
```

Caveats:

- Any withdrawals queued between the forward-upgrade and the rollback carry
  `version=1` envelopes. The pre-upgrade relayer must be able to either process
  them or safely park them until a forward roll-forward. **Do not roll back the
  relayer** unless you are certain no envelope withdrawals are in-flight.
- Storage is preserved across both directions; no slot will be corrupted by a
  round-trip.
- If the rollback is permanent, the P2SH entry points disappear from the ABI —
  SDKs/frontends must revert to the old interface.

---

## 5. References

- Contract source: [`src/dogeos/Moat.sol`](src/dogeos/Moat.sol)
- Interface: [`src/dogeos/IMoat.sol`](src/dogeos/IMoat.sol)
- Address decoder: [`src/dogeos/DogeAddressLib.sol`](src/dogeos/DogeAddressLib.sol)
- Deploy script: [`scripts/deterministic/DeployScroll.s.sol`](scripts/deterministic/DeployScroll.s.sol) (`deployL2Moat`, `deployL2MoatImpl`, `_dogePrefixesFromL1ChainId`)
- Deploy impl shell script: [`scripts/deterministic/shell/deploy-moat-impl.sh`](scripts/deterministic/shell/deploy-moat-impl.sh)
- Upgrade proxy shell script: [`scripts/deterministic/shell/submit-moat-proxy-upgrade.sh`](scripts/deterministic/shell/submit-moat-proxy-upgrade.sh)
- Tests: [`src/test/dogeos/Moat.t.sol`](src/test/dogeos/Moat.t.sol)
- Merge commit: `3e29ab0` (`feat/p2sh-withdrawals` → `dogeos-v0.3.0-develop`)
- Source commit: `4cfcad9 feat(moat): add P2SH withdrawal support with message envelope encoding`
