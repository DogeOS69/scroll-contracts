# Transient relay sender: execution budget and upgrade scope

This change is stacked on PR #63 (`2b190baeea28af95552ad577fe9484e7ebadf488`).
Only `L2DogeOsMessenger` uses transient sender context. Moat and messenger
reentrancy guards remain OpenZeppelin's storage-based implementation.

The old sender field remains at slot 201, with the same address type and offset.
The explicit virtual getter preserves the external ABI. During a DogeOS relay it
returns `uint160(transientValue - 1)`; outside a relay it returns the untouched
legacy slot, including the zero value before initialization. The relay hot path
uses the initialized proxy's default-sender sentinel directly, avoiding that
legacy read. Relays are supported on initialized proxies. L1 and ordinary L2
messengers continue reading/writing the storage field.

Every normal return clears the transient context, including a caught target
revert. An enclosing reverted call frame rolls back its transient writes. The
encoding supports both the zero address and the maximum uint160 address.

## Fixed-block benchmark

A local Anvil Cancun fork uses Chikyu block **8,394,120**, hash
`0xc6245188623c2b0d67dd190c31864e05a1fa243852b38734037d1b9c95c6b82a`.
Both sides install the same PR #65 Moat implementation
(`08baad46eabae187b9df9d0627df204b53bca788`) behind the existing proxy. Only the
messenger implementation differs between the before/after measurements.
Compilation uses solc 0.8.24, optimizer 200 runs, Cancun, no metadata hash, and
OpenZeppelin 4.9.3. Total transaction gas is **200,000**, deposit value 10 DOGE,
and the existing deposit fee is 1 DOGE.

| Configuration                                   | Bitmap word                      | Baseline gross gas before → after | Max successful recipient burn before → after |
| ----------------------------------------------- | -------------------------------- | --------------------------------: | -------------------------------------------: |
| Existing network, legacy check enabled          | Empty                            |                  102,770 → 97,858 |                              94,614 → 99,512 |
| Existing network, legacy check enabled          | Populated by a prior transaction |                   85,670 → 80,758 |                            109,866 → 114,547 |
| Fresh-network cost model, legacy check disabled | Empty                            |                  100,580 → 95,668 |                             96,784 → 101,713 |
| Fresh-network cost model, legacy check disabled | Populated by a prior transaction |                   83,480 → 78,568 |                            111,974 → 116,655 |

Gross execution saves **4,912 gas** per measured deposit. Ordinary Ethereum
receipt accounting reports only 2,112 saved because the old sender reset earned a
2,800-gas refund; DogeOS L1 messages do not apply that refund. As a calibration,
replaying real type-0x7e deposit
`0xcf85d865fffc4a1ff2ac61ddf6056ad763ea8f0fa3c3bc3b8329c4822674211a`
from parent block 8,372,809 used 114,266 gross gas, exactly matching its chain
receipt (ordinary Anvil net gas was 108,666).

The burner has 31-gas granularity. Each reported boundary is the last successful
measured burn, not an exact universal gas limit. The next step fails. Actual
local transactions verify credit at the successful boundary and no credit at
the failing boundary. A 100,039-gas burn still fails for the upgraded legacy
network's empty bitmap word; it succeeds in the other three after-change cases.
The populated word is initialized in a separate transaction, so its storage
access is cold, not artificially warm or dirty from setup in the measured call.

These are local execution measurements, not mainnet guarantees. The
legacy-check-disabled rows are a hypothetical fresh-network cost model; disabling
that check on the existing chain is unsafe and is not proposed. The benchmark
substitutes implementation pointers only in its isolated fork; it does not test
operator upgrade authorization or submit any public-chain transactions.

Machine-readable results, input calldata, runtime hashes, success/failure
boundaries and local credit checks are in `transient-sender-results.json`.

## Reproduce

Use Python 3 and Foundry (`anvil`, `cast`). Prepare three source checkouts:

- `before`: PR #63 at `2b190baeea28af95552ad577fe9484e7ebadf488`.
- `after`: this PR.
- `moat`: PR #65 at `08baad46eabae187b9df9d0627df204b53bca788`.

Install the lockfile dependencies, or just OpenZeppelin contracts and
contracts-upgradeable **4.9.3**, in each checkout's `node_modules`. From each
messenger checkout, using the solc **0.8.24** binary:

```sh
solc --base-path . --optimize --optimize-runs 200 --evm-version cancun \
  --metadata-hash none --combined-json abi,bin \
  '@openzeppelin/=node_modules/@openzeppelin/' \
  src/dogeos/L2DogeOsMessenger.sol > /tmp/messenger-before.json
```

For the after checkout use `/tmp/messenger-after.json` as output. In the Moat
checkout use `src/dogeos/Moat.sol` and `/tmp/moat.json` instead. Then run from this
PR checkout:

```sh
python3 scripts/benchmarks/transient-sender.py \
  --before /tmp/messenger-before.json \
  --after /tmp/messenger-after.json \
  --moat /tmp/moat.json \
  --output /tmp/transient-sender-results.json
```

The script starts and stops its own localhost Anvil process on an available
port. Public RPC is read only. The default archive endpoint and block can be
overridden with `--fork-url` and `--block`; the deployed contract addresses and
expected 1 DOGE fee belong to this Chikyu fixture.

## Validation and deployment gate

- Foundry regression suite: 536 tests passed, including sender fuzzing,
  zero/max sender, same-transaction success/failure/retry, rejected nested relay,
  enclosing-frame rollback, historical replay protection and proxy upgrades.
- A recorded-access assertion verifies the hot path, including the receiver's
  sender getter call, does not read or write legacy sender slot 201.
- Compiled external ABI and every storage slot/type/offset match PR #63.
- Solhint on changed production files: no errors; existing style warnings and
  the intentional assembly/low-level-call warnings remain.

**Before deployment:** prove devnet blocks containing deposits and withdrawals
through this implementation, including failed delivery and sender observations.
The local Cancun fork does not establish prover support for `TLOAD`/`TSTORE`.
That end-to-end proving run has not been performed for this PR. This remains an
explicit deployment gate, as it was for the closed PR #64.
