# Testnet L2 proxy upgrades (one-off)

**Testnet only.** DogeOS testnet (L2 chain 6281971) keeps its L2 chain through
the TsukiV2 upgrade, so the L2 contracts it deployed on 2026-09-10 are upgraded
in place to this tree. Mainnet starts from a genesis that already carries these
implementations and never runs anything here. **Remove this directory** once
testnet's Moat and messenger proxies run this tree's implementations (or testnet
is regenesised).

Everything else is the generic tooling in `scripts/deterministic/shell/` and
`UPGRADE_MOAT.md`; this directory only adds the testnet-specific evidence, the
order and a fork dry run.

## What testnet runs, and what changes

Read from testnet's public RPC at L2 block 9,399,544 and compared with this
tree's compiled runtime code (immutables masked):

| Contract                                                             | Testnet                                                                                  | Action                                                                                                                |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `L2DogeOsMessenger` (proxy `0xe9C5…C96a`)                            | implementation built from `28f6ca9`                                                      | **Upgrade**: a pause no longer blocks deposit relays (#71); no send timestamp written (#62)                           |
| `Moat` (proxy `0xb469…c00f`)                                         | implementation built from `28f6ca9`                                                      | **Upgrade**: fees held until `sweepFees()` (#65); messenger bound immutably (#57); single-pass address decoding (#55) |
| `WrappedDoge` (predeploy, not a proxy)                               | identical to this tree                                                                   | None: the ERC20Permit import change (#88) does not change bytecode                                                    |
| `FeeVaultMoatAdapter`, `L2SystemConfig`, `L2TxFeeVault`, `Whitelist` | identical                                                                                | None                                                                                                                  |
| `L2MessageQueue` (predeploy)                                         | Merkle-tree queue                                                                        | Not a proxy: swapped to the hash chain by the node at TsukiV2                                                         |
| `L1GasPriceOracle` (predeploy)                                       | Galileo code the node installed at the fork, without the `ErrInvalidPenaltyFactor` guard | Not a proxy: node-side (`UPGRADE_GALILEO.md` B.1). Harmless while `penaltyFactor` is non-zero (it is 10,000)          |

The `28f6ca9` builds of `Moat` and `L2DogeOsMessenger` match the deployed runtime
code byte for byte (immutables masked). `deployed-layouts/` holds their storage
layouts, and `check-upgrade-layout.py` checks this tree against them. The only
layout change is the rename of Moat slot 51 (`messenger` to
`_deprecatedMessengerSlot`; it keeps its value). Nothing is appended.

Pinned implementations (keccak of the deployed runtime code, immutables
included). The dry run stops if testnet's implementation is no longer this one:

| Contract          | Implementation                               | Code hash                                                            |
| ----------------- | -------------------------------------------- | -------------------------------------------------------------------- |
| L2DogeOsMessenger | `0xf0fd39cd867d17f6494e8b4f50771f8563397993` | `0xafbf5f384c995ff832c1739b41069af163c3aede69e4dcb030f1feb3c9282b93` |
| Moat              | `0x3AfbBaA1854B6F052D2fF5eF3Dd6aF918052dAAE` | `0x08e92ba5cd7bcece9849a49468c7293c30d835d4e98c798b14db004df18dd7d7` |

Both upgrades need no re-initialisation and keep every event the bridge services
read (the Moat adds `FeesSwept`). The new messenger calls the queue exactly as
the old one does (`nextMessageIndex()`, `appendMessage(bytes32)`), so it works
against the Merkle-tree queue before TsukiV2 and the hash chain after it. The
two upgrades are independent of each other.

## Order

Prepare `volume/` as in `UPGRADE_MOAT.md` 1.2 (testnet's `config.toml` and
`config-contracts.toml`), then from the repository root:

```bash
python3 scripts/testnet-upgrade/check-upgrade-layout.py

# Before the window: messenger implementation (needed for a withdrawals-only pause)
scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh
BROADCAST=1 scripts/deterministic/shell/deploy-dogeos-messenger-impl.sh
scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 scripts/deterministic/shell/submit-dogeos-messenger-proxy-upgrade.sh

# Draining (plan step "pause withdrawals on L2")
scripts/deterministic/shell/submit-dogeos-messenger-pause.sh pause
OWNER_PRIVATE_KEY=0x... BROADCAST=1 scripts/deterministic/shell/submit-dogeos-messenger-pause.sh pause

# Reopening (plan step "upgrade the remaining L2 contract proxies")
scripts/deterministic/shell/deploy-moat-impl.sh
BROADCAST=1 scripts/deterministic/shell/deploy-moat-impl.sh
scripts/deterministic/shell/submit-moat-proxy-upgrade.sh
OWNER_PRIVATE_KEY=0x... BROADCAST=1 scripts/deterministic/shell/submit-moat-proxy-upgrade.sh

# Reopening, last step (plan step "unpause withdrawals")
OWNER_PRIVATE_KEY=0x... BROADCAST=1 scripts/deterministic/shell/submit-dogeos-messenger-pause.sh unpause
```

- The pause script simulates a deposit relay with the paused flag forced on and
  refuses to pause while that relay would revert. Against testnet's messenger as
  deployed today it refuses: pausing that implementation would also stop
  deposits.
- After the Moat upgrade, fees stay in the Moat. Schedule `sweepFees()`
  (permissionless; `UPGRADE_MOAT.md` "Fees held by the Moat").
- The Moat upgrade could also run before the window. The plan places it at
  reopening.
- Rollback: `UPGRADE_MOAT.md` 1.7, with the old implementation addresses above.
  Rolling the messenger back brings back pauses that block deposits (1.8).
- One owner (`0x40eC…fB0A`) holds the ProxyAdmin, messenger and Moat on testnet.
- If a Moat change such as two-step ownership lands first, rerun
  `check-upgrade-layout.py`. An appended variable passes; anything else fails.

## Dry run on a fork

```bash
CONFIG_CONTRACTS=/path/to/testnet/config-contracts.toml scripts/testnet-upgrade/dry-run-fork.sh
```

Forks testnet L2 with anvil and runs the commands above with `BROADCAST=1`
(signing with anvil's dev key after the fork hands it ownership). It checks:

- proxy storage and wiring are unchanged across each upgrade;
- while paused, a withdrawal is refused and a deposit is credited;
- after the unpause, a Moat withdrawal and a fee vault withdrawal (through the
  adapter) are queued, and the Moat holds the withdrawal fee;
- `sweepFees()` pays the held fees to `feeRecipient`.

It touches nothing but the fork and deletes the `volume/` it creates.
