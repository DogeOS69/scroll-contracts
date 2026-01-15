# Moat Dogecoin Addressing & Message Envelope

## Overview

- `Moat` wraps `IL2ScrollMessenger.sendMessage` for L2→L1 withdrawals. The `message` field is now used to carry Dogecoin address metadata; it is emitted in `SentMessage` and committed in the withdrawal root hash (`_encodeXDomainCalldata`).
- The `target` address carries the 20-byte hash160 payload of the Dogecoin destination. `gasLimit` remains gas-only and is not used for metadata.

## Message Envelope

- Format: `version (1 byte) | flags (1 byte)`.
- `version=0`: legacy behavior (empty `message`), treated as P2PKH.
- `version=1`: current format.
  - `flags`: bit0 = `1` → P2SH, `0` → P2PKH. Other bits reserved for future use (e.g., witness/script policy).
- Network prefix is not encoded in the envelope; the deployed chain (mainnet/testnet/regtest) implies the prefix. Auditing still succeeds because `message` is part of `SentMessage` and the withdrawal root; chain context supplies the prefix.

## Entry Points

- `withdrawToP2PKH(address target)`: target is hash160 (address-typed), flags=0.
- `withdrawToP2SH(address target)`: target is script hash (address-typed), flags=P2SH.
- `withdrawToL1(address target)`: backward-compatible alias for `withdrawToP2PKH`.
- `withdrawToDogeAddress(string dogeAddress)`: base58check decode on-chain; enforces configured prefixes and routes to P2PKH/P2SH accordingly.
- All share fee/min-withdrawal checks and emit `WithdrawalQueued` with the post-fee amount; the messenger call uses the envelope described above.

-## Network Configuration

- Prefixes map:
- - mainnet: P2PKH `0x1e`, P2SH `0x16`
- - testnet: P2PKH `0x71`, P2SH `0xc4`
- - regtest: P2PKH `0x6f`, P2SH `0xc4`
- Configuration should be set once during initialization. Two viable approaches for upgradeability:
  1. One-time storage setter (e.g., `configureNetwork`) gated so legacy proxies can initialize the new slot during upgrade; reverts on re-entry to avoid accidental switches.
  2. Immutable/constant in code per build (distinct artifacts for mainnet/testnet/regtest); upgrade requires deploying the variant that matches the chain and pointing the proxy there (cannot misconfigure at runtime).
- Withdrawals should revert until a prefix is configured (if using approach 1). Off-chain components must assume the chain’s canonical prefixes regardless of envelope contents.

## Compatibility & Upgrade Notes

- Legacy withdrawals (empty `message`) remain valid and are interpreted as `version=0`, P2PKH.
- New withdrawals emit `version=1` envelopes; off-chain components must recognize both.
- The address payload remains 20 bytes; only script-type metadata moves into the `message` field, keeping withdrawal roots deterministic.

## Address Conversion Library

- Extract Dogecoin base58check decode + prefix validation + payload extraction into a dedicated Solidity library (e.g., `DogeAddressLib.sol`), linked/inlined—no separate deployment.
- Library should expose pure/internal helpers:
  - `decode(string addr) returns (bytes1 prefix, bytes20 payload)`
  - `isP2PKH(bytes1 prefix)`, `isP2SH(bytes1 prefix)`
  - Optional: `decodeChecked(string addr, bytes1 p2pkhPrefix, bytes1 p2shPrefix) returns (bool isP2SH, bytes20 payload)`
- Moat uses the library to parse `withdrawToDogeAddress` and route to P2PKH/P2SH entry points.

## Tests to Add

- Envelope encoding:
  - `withdrawToP2PKH` emits `version=1, flags=0`; `withdrawToP2SH` emits `version=1, flags=P2SH`.
  - Legacy path `withdrawToL1` / empty message stays `version=0`.
- Prefix gating:
  - Withdrawals revert if prefixes are unset (approach 1) or if the parsed address prefix mismatches the configured chain.
  - Accept valid mainnet/testnet/regtest prefixes; reject others.
- Base58check decoding (library-focused):
  - Valid P2PKH/P2SH addresses decode to expected prefix/payload.
  - Invalid length, bad characters, bad checksum revert.
  - Leading-zero handling (addresses with base58 leading `1`).
- Route selection:
  - `withdrawToDogeAddress` routes P2PKH vs P2SH correctly and emits the right flags.
  - Amount/fee/min withdrawal logic unchanged across entry points.
- Upgrade safety:
  - If using one-time setter, ensure reconfiguration reverts after first set and storage is preserved across upgrades.
