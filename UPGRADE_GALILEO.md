# Galileo Upgrade — Contract Upgrade Guide

This document describes how to upgrade the `L1GasPriceOracle` predeploy at
`0x5300000000000000000000000000000000000002` to the Galileo version.

---

## 1. What changes

### 1.1 Fee formula

Galileo replaces the Feynman piecewise threshold-based compression penalty with
a single quadratic term driven only by `penaltyFactor`:

```
baseTerm    = (commitScalar * l1BaseFee + blobScalar * l1BlobBaseFee) * len
penaltyTerm = baseTerm * len / penaltyFactor
fee         = (baseTerm + penaltyTerm) / PRECISION
```

`penaltyThreshold` no longer participates in fee computation.

### 1.2 ABI changes

| Change                                                                     | Kind       |
| -------------------------------------------------------------------------- | ---------- |
| Remove `setPenaltyThreshold(uint256)`                                      | breaking   |
| Remove event `PenaltyThresholdUpdated(uint256)`                            | breaking   |
| Relax `setPenaltyFactor` check to `factor != 0`                            | behavior   |
| `getL1Fee(bytes)` signature unchanged, computation changed                 | behavior   |
| Add `enableGalileo()` owner-only                                           | additive   |
| Add `isGalileo()` auto-getter (slot `0x0c`)                                | additive   |
| Add error `ErrAlreadyInGalileoFork`                                        | additive   |
| `penaltyThreshold()` kept as deprecated view, returns `__penaltyThreshold` | compatible |

### 1.3 Storage layout

Slots preserved (owner, `l1BaseFee`, `overhead`, `scalar`, `l1BlobBaseFee`,
`commitScalar`, `blobScalar`, `isCurie`, `penaltyFactor`, `isFeynman`).

| Slot   | Field                              | Notes                                                                                                                                                   |
| ------ | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x09` | `__penaltyThreshold`               | renamed from `penaltyThreshold`; no longer read by fee logic                                                                                            |
| `0x0a` | `penaltyFactor`                    | preserved; the Galileo formula **divides** by it, so it must be non-zero whenever `isGalileo` is set (fresh genesis now seeds it from `PENALTY_FACTOR`) |
| `0x0b` | `bool isFeynman` + `uint248 __gap` | packed; `__gap` ensures `isGalileo` owns a fresh slot                                                                                                   |
| `0x0c` | `bool isGalileo`                   | new                                                                                                                                                     |

**⚠️ Storage compatibility rule**: the upgrade must not touch slots
`0x00`–`0x0b`. Only slot `0x0c` (`isGalileo`) is newly set.

### 1.4 Post-Galileo technical fee guard

The current contract source adds an on-chain numerical-safety boundary around
the Galileo fee tuple. This is deliberately **not** an economic pricing policy:
the fee-oracle service remains responsible for determining whether a candidate
is commercially reasonable. The contract protects transaction liveness from
unit, decimal, overflow, and other astronomical-input failures.

The guard has two independently reviewable parameters:

| Constant                     | Value               | Meaning                                                               |
| ---------------------------- | ------------------- | --------------------------------------------------------------------- |
| `FEE_GUARD_COMPRESSED_BYTES` | `512`               | Conservative reference size for a minimal signed recovery transaction |
| `MAX_GUARDED_L1_FEE`         | `10_000 * 1e18` wei | 10,000 DOGE technical ceiling for that reference transaction          |

Both values are initial engineering estimates, not permanent protocol truths.
They should be reevaluated together using measured compressed sizes of the
actual signed recovery transactions, execution-client limits, native-token
denomination, and operational headroom before a production activation or a
future fee-formula upgrade.

There is deliberately no independent cap on `l1BaseFee` or `l1BlobBaseFee`.
Those fields and the scalar fields only become meaningful through their
combined result. A candidate with an individual value above `uint64` is valid
when the complete tuple remains below the technical ceiling; a candidate with
smaller-looking individual values is rejected when their complete result is
unsafe. The execution client reads and calculates the raw fee fields as
`U256`; its final rollup-fee representation or clamp is a separate client
concern and must not be reused as an oracle-field policy.

Before changing storage, each active-Galileo fee setter reconstructs the
complete candidate tuple and applies the exact Galileo formula at 512 bytes:

```text
baseTerm =
  (commitScalar * l1BaseFee + blobScalar * l1BlobBaseFee) * 512

penaltyTerm = baseTerm * 512 / penaltyFactor

guardedFee = (baseTerm + penaltyTerm) / 1e9
```

The write reverts if `guardedFee > MAX_GUARDED_L1_FEE`. Validation covers
`setL1BaseFee`, `setL1BaseFeeAndBlobBaseFee`, `setCommitScalar`,
`setBlobScalar`, `setPenaltyFactor`, and the owner-callable `enableGalileo`
helper. An individually large dynamic value can therefore be stored while its
corresponding scalar is zero, but any later update that would make that value
produce an unsafe fee is rejected before storage changes.

The shared `_calculateGalileoFee` helper is used by both `getL1Fee` and the
guard to prevent formula drift. The constants consume no storage slots, and
the guard adds no mutable storage, so the layout above remains unchanged.

The initial 10,000 DOGE ceiling is intentionally permissive: a tested 512-byte
tuple with a fee of approximately 121.64 DOGE is accepted. Stricter market and
profitability limits belong in fee-oracle policy and operational monitoring.

---

## 2. Upgrade paths

### Path A — Fresh genesis (new chain)

The `genesis.json` template + `GenerateGenesis.s.sol` flow in this repo already
handles this. No additional action needed beyond building with this branch.

### Path B — Live chain (existing deployment)

Modifying `genesis.json` does **not** affect a running chain. The contract code
and `isGalileo` flag are rewritten by L2 geth itself at the fork transition —
the Galileo runtime bytecode is embedded in the geth binary (scroll-tech
upstream), so **no custom fork hook work is needed in this repo**.

#### B.1 L2 geth version requirement

Upgrade every node to L2 geth **≥ [`scroll-v5.10.0`](https://github.com/scroll-tech/go-ethereum/releases/tag/scroll-v5.10.0)**. That release:

- Ships the Galileo `L1GasPriceOracle` runtime bytecode inside the binary.
- Applies the contract-code swap and storage update (`isGalileo = true` at slot
  `0x0c`) automatically at `galileoTime`, preserving all other slots.
- Genesis file / `alloc` contents are **not** consulted for this transition —
  the upgrade is driven purely by `galileoTime` / `galileoV2Time` in the chain
  config.

No manual `forge inspect` export, no embedding of bytecode, and no custom
`ApplyGalileoHardFork` implementation was needed for the original GalileoV2
release. Its historical embedded bytecode must remain unchanged. The current
Solidity source intentionally includes the newer guard described below and
therefore requires a separate future transition on an already-running chain.

#### B.1.1 Deploying the post-Galileo fee guard

The technical fee guard in section 1.4 is newer than the original GalileoV2
runtime bytecode. On a network that has already crossed `galileoV2Time`, the
guard **cannot** be activated by changing this Solidity repository, changing
genesis allocation, or changing the bytecode constant used at the historical
GalileoV2 transition.

In particular, never replace the bytecode installed at an already-canonical
historical transition: a node syncing from genesis would compute a different
historical code hash and state root.

Deploy the guarded runtime through a new, future, coordinated client hardfork:

1. preserve the original GalileoV2 bytecode and historical transition exactly;
2. compile and pin the guarded `L1GasPriceOracle` runtime bytecode;
3. add a new hardfork identifier and future activation timestamp;
4. atomically replace only the code at `0x5300…0002`, preserving slots
   `0x00`–`0x0c`;
5. make the transition idempotent using a new code-version marker or an exact
   code-hash check;
6. ship the same binary and chain configuration to every sequencer, follower,
   RPC, and verifier before activation;
7. verify the new code hash and all preserved fee fields after activation.

The execution client must allow legitimate total rollup fees above `uint64`.
The current post-Tsuki revm path calculates the raw values in `U256` and clamps
the final L1 cost to `U96_MAX`; this client-side representation remains
separate from the contract's 10,000 DOGE reference-transaction liveness guard.

Before `galileoTime`, confirm `penaltyFactor() != 0` on the oracle (slot
`0x0a`): the Galileo formula divides by it, and `getL1Fee` reverts with
`ErrInvalidPenaltyFactor` while it is unset. On a configured live chain it is
already non-zero (`setPenaltyFactor` rejects zero); fresh genesis seeds it.

Note: this repo's source now guards that division explicitly
(`ErrInvalidPenaltyFactor` instead of `Panic(0x12)`). A geth build embedding
the pre-guard bytecode installs that version at the fork — harmless on a
configured chain, but sync the geth-embedded bytecode with this source at the
next geth release so fresh-genesis and forked networks converge on identical
oracle code.

#### B.2 Required chain config update

In the rollup node / sequencer / follower / bridge-history config:

```json
{
  "config": {
    "...": "...",
    "galileoTime": <UNIX_TIMESTAMP>,
    "galileoV2Time": <UNIX_TIMESTAMP_LATER>
  }
}
```

- `galileoTime`: activation timestamp for the contract swap.
- `galileoV2Time`: strictly greater than `galileoTime`; governs the
  second-stage consensus changes.

All nodes must share the same activation timestamps.

#### B.3 Release order (critical)

1. Pick activation timestamps far enough in the future to cover rollout.
2. Ship L2 geth `scroll-v5.10.0+` to **all** nodes (sequencer, followers, RPC,
   bridge-history, rollup-relayer). Verify every node is on a supported version
   **before** `galileoTime`. Any node still on an older build will fork away at
   the transition.
3. Distribute the updated chain config with `galileoTime` / `galileoV2Time` set.
4. At `galileoTime`, each node's embedded fork routine rewrites the oracle
   bytecode at `0x5300…0002` and sets `isGalileo = true` in its local state
   trie — deterministically and atomically, so every honest node produces the
   same post-fork state root.

#### B.4 Post-activation verification

Run on every node (results must match):

```bash
# Contract was upgraded
cast code 0x5300000000000000000000000000000000000002 --rpc-url <L2_RPC> \
  | sha256sum
# compare against sha256 of the Galileo runtime bytecode

# Galileo flag is on
cast call 0x5300000000000000000000000000000000000002 'isGalileo()(bool)' --rpc-url <L2_RPC>
# expect: true

# Historical state preserved
cast call 0x5300000000000000000000000000000000000002 'l1BaseFee()(uint256)' --rpc-url <L2_RPC>
cast call 0x5300000000000000000000000000000000000002 'penaltyFactor()(uint256)' --rpc-url <L2_RPC>
cast call 0x5300000000000000000000000000000000000002 'isFeynman()(bool)' --rpc-url <L2_RPC>
# expect: unchanged compared to pre-fork snapshots

# Deprecated field still readable
cast call 0x5300000000000000000000000000000000000002 'penaltyThreshold()(uint256)' --rpc-url <L2_RPC>
# expect: returns previous __penaltyThreshold value (no longer used in fee math)
```

Also submit a sample transaction and confirm the `getL1Fee` result matches the
Galileo formula within tolerance.

---

## 3. External services to coordinate

| Service                                        | Required action                                                                                                             |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| L2 geth (all roles)                            | Upgrade binary to `scroll-v5.10.0+`; update chain config with `galileoTime` / `galileoV2Time`                               |
| rollup-relayer                                 | Ensure batch/gas estimation uses on-chain `getL1Fee` (no hardcoded formula)                                                 |
| `fee_oracle` (`dogeos-core/crates/fee_oracle`) | Code-level no-op; optional cleanup of `ErrInvalidPenaltyThreshold` and add `ErrAlreadyInGalileoFork` in updater error table |
| Admin / ops scripts                            | Remove `setPenaltyThreshold` calls (will revert after upgrade)                                                              |

---

## 4. Rollback

The Galileo transition is a hard fork — rolling back means a coordinated
client downgrade across every node plus a chain config revert before the
activation timestamp is crossed. After activation, rollback is effectively a
reorg and should not be attempted operationally. Mitigation strategy:

1. Rehearse on a staging network with the same config shape first.
2. Keep the pre-Galileo geth binary available for emergency downgrade **only
   before** `galileoTime` is reached on mainnet.
3. If a defect is discovered after activation, address it by coordinating a
   geth patch release and moving `galileoV2Time` rather than rolling back.

---

## 5. References

- Contract source: [`src/L2/predeploys/L1GasPriceOracle.sol`](src/L2/predeploys/L1GasPriceOracle.sol)
- Interface: [`src/L2/predeploys/IL1GasPriceOracle.sol`](src/L2/predeploys/IL1GasPriceOracle.sol)
- Genesis template: [`docker/templates/genesis.json`](docker/templates/genesis.json)
- Genesis generator: [`scripts/deterministic/GenerateGenesis.s.sol`](scripts/deterministic/GenerateGenesis.s.sol)
- Deploy script: [`scripts/deterministic/DeployScroll.s.sol`](scripts/deterministic/DeployScroll.s.sol)
- Tests: [`src/test/L1GasPriceOracle.t.sol`](src/test/L1GasPriceOracle.t.sol)
