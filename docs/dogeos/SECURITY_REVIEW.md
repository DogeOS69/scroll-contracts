# Security Review: P2SH Withdrawals Feature

**Reviewed Branch:** `feat/p2sh-withdrawals`
**Base Branch:** `dogeos`
**Commit:** `4cfcad9 feat(moat): add P2SH withdrawal support with message envelope encoding`
**Date:** 2026-01-15
**Tools Used:** Slither 0.11.4, Manual Analysis

---

## Executive Summary

This review analyzes the P2SH withdrawal feature addition to the DogeOS Moat contract. The changes introduce:

1. A new `DogeAddressLib` library for Base58Check Dogecoin address decoding
2. New withdrawal entry points (`withdrawToP2PKH`, `withdrawToP2SH`, `withdrawToDogeAddress`)
3. Message envelope encoding to distinguish P2PKH vs P2SH withdrawals
4. Immutable network prefix configuration (P2PKH_PREFIX, P2SH_PREFIX)

**Risk Level: MEDIUM** - The implementation is generally sound but has areas requiring attention.

---

## Entry Point Analysis

### Contract: Moat (src/dogeos/Moat.sol)

| Category                  | Function                           | Modifiers               | Risk   |
| ------------------------- | ---------------------------------- | ----------------------- | ------ |
| **Public (Unrestricted)** | `withdrawToL1(address)`            | `nonReentrant, payable` | HIGH   |
| **Public (Unrestricted)** | `withdrawToP2PKH(address)`         | `nonReentrant, payable` | HIGH   |
| **Public (Unrestricted)** | `withdrawToP2SH(address)`          | `nonReentrant, payable` | HIGH   |
| **Public (Unrestricted)** | `withdrawToDogeAddress(string)`    | `nonReentrant, payable` | HIGH   |
| **Public (Unrestricted)** | `handleL1Message(address,bytes32)` | `nonReentrant, payable` | HIGH   |
| **Admin (onlyOwner)**     | `initialize(address)`              | `initializer`           | MEDIUM |
| **Admin (onlyOwner)**     | `updateMessenger(address)`         | `onlyOwner`             | MEDIUM |
| **Admin (onlyOwner)**     | `setWithdrawalFee(uint256)`        | `onlyOwner`             | LOW    |
| **Admin (onlyOwner)**     | `setDepositFee(uint256)`           | `onlyOwner`             | LOW    |
| **Admin (onlyOwner)**     | `setMinWithdrawal(uint256)`        | `onlyOwner`             | LOW    |
| **Admin (onlyOwner)**     | `setFeeRecipient(address)`         | `onlyOwner`             | LOW    |
| **Admin (onlyOwner)**     | `setBascule(address)`              | `onlyOwner`             | MEDIUM |
| **Admin (onlyOwner)**     | `transferOwnership(address)`       | `onlyOwner`             | HIGH   |
| **Admin (onlyOwner)**     | `renounceOwnership()`              | `onlyOwner`             | HIGH   |

### Contract: L2DogeOsMessenger (src/dogeos/L2DogeOsMessenger.sol)

| Category   | Function                  | Modifiers                | Risk   |
| ---------- | ------------------------- | ------------------------ | ------ |
| **Public** | `sendMessage(...)`        | `whenNotPaused, payable` | HIGH   |
| **Public** | `relayMessage(...)`       | `whenNotPaused`          | HIGH   |
| **Admin**  | `initialize(address)`     | `initializer`            | MEDIUM |
| **Admin**  | `setPause(bool)`          | `onlyOwner`              | MEDIUM |
| **Admin**  | `updateFeeVault(address)` | `onlyOwner`              | LOW    |

### Contract: WrappedDoge (src/dogeos/WrappedDoge.sol)

| Category   | Function                        | Modifiers | Risk   |
| ---------- | ------------------------------- | --------- | ------ |
| **Public** | `deposit()`                     | `payable` | LOW    |
| **Public** | `withdraw(uint256)`             | -         | MEDIUM |
| **Public** | `transfer/approve/transferFrom` | -         | LOW    |

### Contract: BasculeMockVerifier (src/dogeos/BasculeMockVerifier.sol)

| Category   | Function                  | Modifiers | Risk |
| ---------- | ------------------------- | --------- | ---- |
| **Public** | `validateWithdrawal(...)` | -         | HIGH |

**Note:** This is a mock verifier that allows all withdrawals except a hardcoded test ID. **MUST be replaced in production.**

---

## Differential Review Findings

### Files Changed

| File                                       | Change Type | Lines    | Risk |
| ------------------------------------------ | ----------- | -------- | ---- |
| `src/dogeos/DogeAddressLib.sol`            | NEW         | +166     | HIGH |
| `src/dogeos/Moat.sol`                      | MODIFIED    | +108/-57 | HIGH |
| `src/dogeos/IMoat.sol`                     | MODIFIED    | +16/-11  | LOW  |
| `src/test/dogeos/Moat.t.sol`               | MODIFIED    | +473     | N/A  |
| `scripts/deterministic/DeployScroll.s.sol` | MODIFIED    | +27      | LOW  |

---

## Security Findings

### CRITICAL

_None identified_

### HIGH

#### H-1: Missing Zero-Address Check on Withdrawal Target

**Location:** `Moat.sol:289` (`_processWithdrawal`)

**Description:** The `_target` parameter in withdrawal functions is not validated against `address(0)`. Users could accidentally withdraw to the zero address, resulting in permanent loss of funds.

**Affected Functions:**

- `withdrawToL1(address _target)`
- `withdrawToP2PKH(address _target)`
- `withdrawToP2SH(address _target)`

**Recommendation:** Add zero-address validation:

```solidity
if (_target == address(0)) {
    revert ErrorZeroAddress();
}
```

**Slither Reference:** `missing-zero-check` detector flagged `handleL1Message._target`

---

#### H-2: Arbitrary ETH Send in Fee Transfer

**Location:** `Moat.sol:315`

**Description:** Slither detected `arbitrary-send-eth` pattern. While the fee recipient is owner-controlled, if `feeRecipient` is set to a malicious contract, it could:

1. Revert intentionally to grief withdrawals (mitigated by `if (feeRecip != address(0) && fee > 0)` check)
2. Perform reentrancy (mitigated by `nonReentrant`)

**Current Code:**

```solidity
(bool success, ) = feeRecip.call{value: fee}("");
if (!success) revert ErrorFeeTransferFailed();
```

**Status:** Acceptable risk - owner-controlled, reentrancy protected

---

### MEDIUM

#### M-1: DogeAddressLib Assembly Usage Requires Careful Review

**Location:** `DogeAddressLib.sol:111-116`

**Description:** The library uses inline assembly to extract the 20-byte payload:

```solidity
assembly {
    payloadBytes := mload(add(decoded, 33))
}
```

**Analysis:** This is correct:

- `decoded` is a `bytes memory` array
- First 32 bytes = length
- Offset 33 = position after length (32) + prefix byte (1)
- `mload` at this position correctly loads 32 bytes, of which the first 20 are the payload

**Recommendation:** Add fuzz tests for edge cases with unusual leading zeros.

---

#### M-2: Base58 Character Mapping Correctness

**Location:** `DogeAddressLib.sol:150-165`

**Description:** The `_base58CharToValue` function maps ASCII characters to Base58 values. Verification:

| Range   | ASCII   | Expected Values | Calculation | Result |
| ------- | ------- | --------------- | ----------- | ------ |
| '1'-'9' | 49-57   | 0-8             | c - 49      | ✓      |
| 'A'-'H' | 65-72   | 9-16            | c - 56      | ✓      |
| 'J'-'N' | 74-78   | 17-21           | c - 57      | ✓      |
| 'P'-'Z' | 80-90   | 22-32           | c - 58      | ✓      |
| 'a'-'k' | 97-107  | 33-43           | c - 64      | ✓      |
| 'm'-'z' | 109-122 | 44-57           | c - 65      | ✓      |

**Excluded (correctly):** `0`, `O`, `I`, `l`

**Status:** Verified correct

---

#### M-3: Envelope Version Upgrade Path

**Location:** `Moat.sol:27-30`

**Description:** Constants define envelope format:

```solidity
uint8 private constant ENVELOPE_VERSION = 1;
uint8 private constant FLAG_P2SH = 0x01;
```

**Concern:** The L1 message consumer must correctly parse:

- Version 0 (legacy) = treat as P2PKH (empty message data)
- Version 1, flags=0x00 = P2PKH
- Version 1, flags=0x01 = P2SH

**Recommendation:** Ensure L1 bridge/relayer code handles all three cases. Document envelope format specification.

---

#### M-4: setBascule Allows Zero Address

**Location:** `Moat.sol:160-164`

**Description:** The `setBascule` function intentionally allows setting verifier to `address(0)` to disable verification:

```solidity
function setBascule(address _newVerifier) external onlyOwner {
  // We allow setting verifier to address(0) to disable verification if needed.
  address oldVerifier = basculeVerifier;
  basculeVerifier = _newVerifier;
  emit BasculeVerifierUpdated(oldVerifier, _newVerifier);
}

```

**Risk:** If accidentally set to zero, all L1→L2 messages bypass verification.

**Recommendation:** Consider requiring explicit `disableVerification()` function instead of zero address.

---

### LOW

#### L-1: Deprecated Function Without Deprecation Notice in Events

**Location:** `Moat.sol:234-241`

**Description:** `withdrawToL1` is marked deprecated in comments but:

1. Emits same `WithdrawalQueued` event as new functions
2. No on-chain deprecation marker

**Recommendation:** Consider emitting a distinct event or adding a deprecation flag.

---

#### L-2: Immutable Prefix Deployment Risk

**Location:** `Moat.sol:35-38`, `DeployScroll.s.sol:289-308`

**Description:** Network prefixes are immutable. Incorrect deployment configuration cannot be fixed without redeployment.

**Prefixes by Network:**
| Network | P2PKH | P2SH |
|---------|-------|------|
| Mainnet | 0x1e | 0x16 |
| Testnet | 0x71 | 0xc4 |
| Regtest | 0x6f | 0xc4 |

**Recommendation:** Add deployment validation tests that verify prefixes match expected network.

---

#### L-3: Gas Considerations for Base58 Decoding

**Location:** `DogeAddressLib.sol:54-76`

**Description:** The Base58 decoding loop has O(n²) complexity:

- Outer loop: address length (25-35 chars)
- Inner loop: 25 iterations per char

Worst case: ~875 iterations for a 35-char address.

**Status:** Acceptable for L2 execution; document gas costs for callers.

---

### INFORMATIONAL

#### I-1: Test Coverage is Comprehensive

The test file `Moat.t.sol` adds 473+ lines of tests covering:

- Envelope encoding for P2PKH/P2SH
- Base58Check decoding (valid addresses, checksums, invalid chars)
- Fee handling edge cases
- Rejecting fee recipient scenarios

#### I-2: Slither Findings in Other Contracts (Not P2SH Related)

The following Slither findings are in other contracts, not introduced by this PR:

- `unchecked-transfer` in MockGasSwapTarget
- `tx-origin` in EnforcedTxGateway
- `reentrancy-benign` in L2ScrollMessenger, L1ScrollMessenger
- Multiple `missing-zero-check` in various contracts

---

## Attack Surface Analysis

### New Attack Vectors from P2SH Support

1. **Malformed Base58 Address DoS**

   - Mitigation: All invalid addresses revert with specific errors
   - Gas limit protects against excessive computation

2. **Prefix Confusion Attack**

   - Risk: Wrong network prefix could route funds incorrectly
   - Mitigation: Immutable prefixes set at deployment; `ErrorUnrecognizedPrefix` reverts on mismatch

3. **Envelope Spoofing**

   - Risk: Attacker crafts message with wrong version/flags
   - Mitigation: Envelope is created internally by `_encodeEnvelope`, not user-provided

4. **Legacy Message Confusion**
   - Risk: Old `withdrawToL1` calls need correct handling on L1
   - Status: Now uses v1 envelope (flags=0), ensuring backward compatibility

---

## Recommendations Summary

| Priority | Finding                      | Action                                   |
| -------- | ---------------------------- | ---------------------------------------- |
| HIGH     | H-1: Zero address target     | Add validation in `_processWithdrawal`   |
| MEDIUM   | M-3: Envelope versioning     | Document L1 handling requirements        |
| MEDIUM   | M-4: setBascule zero address | Consider explicit disable function       |
| LOW      | L-2: Deployment prefixes     | Add network validation in deploy scripts |

---

## Appendix: Slither Output (DogeOS Specific)

```
Moat._processWithdrawal(address,bool) sends eth to arbitrary user
  - (success,None) = feeRecip.call{value: fee}()

Moat.setBascule(address)._newVerifier lacks a zero-check

Moat.handleL1Message(address,bytes32)._target lacks a zero-check

L2DogeOsMessenger.constructor._feeVault lacks a zero-check

WrappedDoge.withdraw(uint256) sends eth to arbitrary user
  - (success,None) = _sender.call{value: wad}()
```

---

## Files Analyzed

| File                                 | Entry Points    | Status   |
| ------------------------------------ | --------------- | -------- |
| `src/dogeos/Moat.sol`                | 14              | Reviewed |
| `src/dogeos/DogeAddressLib.sol`      | 0 (library)     | Reviewed |
| `src/dogeos/L2DogeOsMessenger.sol`   | 11              | Reviewed |
| `src/dogeos/WrappedDoge.sol`         | 10              | Reviewed |
| `src/dogeos/BasculeMockVerifier.sol` | 1               | Reviewed |
| `src/dogeos/IMoat.sol`               | N/A (interface) | Reviewed |
| `src/dogeos/IBasculeVerifier.sol`    | N/A (interface) | N/A      |
| `src/dogeos/IL2DogeOsMessenger.sol`  | N/A (interface) | N/A      |
| `src/dogeos/IWDOGE.sol`              | N/A (interface) | N/A      |

---

_Report generated using Trail of Bits methodology with Slither 0.11.4_
