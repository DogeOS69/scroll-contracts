# DogeOS Contract Architecture

_Generated from Slither analysis and manual review_

---

## 1. Overview

DogeOS extends the Scroll L2 bridge infrastructure to support Dogecoin (DOGE) as the native asset. The key modifications enable:

- **L2→L1 Withdrawals** to Dogecoin addresses (P2PKH and P2SH)
- **L1→L2 Deposits** with verification via Bascule
- **WDOGE** wrapped native token for DeFi compatibility

---

## 2. Contract Inheritance Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SCROLL BASE CONTRACTS                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Initializable ◄─── ContextUpgradeable ◄─── OwnableUpgradeable         │
│       │                     │                      │                    │
│       │                     └──────────────────────┼───────────────┐    │
│       │                                            │               │    │
│       ├──── PausableUpgradeable                    │               │    │
│       │                                            │               │    │
│       └──── ReentrancyGuardUpgradeable ────────────┼───────────────┤    │
│                                                    │               │    │
│                              ┌─────────────────────┘               │    │
│                              │                                     │    │
│                              ▼                                     ▼    │
│                    ScrollMessengerBase                      OwnableBase │
│                              │                                     │    │
│                              ▼                                     │    │
│                    L2ScrollMessenger                               │    │
│                              │                                     │    │
└──────────────────────────────┼─────────────────────────────────────┼────┘
                               │                                     │
┌──────────────────────────────┼─────────────────────────────────────┼────┐
│                              │     DOGEOS CONTRACTS                │    │
├──────────────────────────────┼─────────────────────────────────────┼────┤
│                              ▼                                     │    │
│                    L2DogeOsMessenger ─────────────────┐            │    │
│                              │                        │            │    │
│                              │ (restricts to MOAT)    │            │    │
│                              │                        │            │    │
│                              │         ┌──────────────┘            │    │
│                              │         │                           │    │
│                              │         ▼                           ▼    │
│                              └──────► Moat ◄───────────── OwnableBase   │
│                                        │                                │
│                                        │ (uses)                         │
│                                        ▼                                │
│                              DogeAddressLib (library)                   │
│                                        │                                │
│                                        │ (calls)                        │
│                                        ▼                                │
│                              IBasculeVerifier                           │
│                                        │                                │
│                                        ▼                                │
│                              BasculeMockVerifier                        │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                     WDOGE (Standalone)                           │   │
│  │                                                                  │   │
│  │  Context ◄── ERC20 ◄── EIP712 ◄── ERC20Permit ◄── WrappedDoge   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### Slither-Generated Inheritance Graph

![Inheritance Graph](./inheritance-graph.svg)

---

## 3. Contract Summaries

### 3.1 Moat (src/dogeos/Moat.sol)

**Purpose:** Central contract for L2→L1 withdrawals and L1→L2 deposit handling

| Property   | Value                                       |
| ---------- | ------------------------------------------- |
| Inherits   | `OwnableBase`, `ReentrancyGuardUpgradeable` |
| Functions  | 27                                          |
| Complexity | High (assembly usage via library)           |
| Features   | Receive ETH, Send ETH, Upgradeable          |

**State Variables:**
| Variable | Type | Description |
|----------|------|-------------|
| `P2PKH_PREFIX` | `bytes1` | Immutable P2PKH version byte |
| `P2SH_PREFIX` | `bytes1` | Immutable P2SH version byte |
| `messenger` | `address` | L2DogeOsMessenger address |
| `basculeVerifier` | `address` | Deposit verification contract |
| `withdrawalFee` | `uint256` | Fee for L2→L1 withdrawals |
| `depositFee` | `uint256` | Fee for L1→L2 deposits |
| `minWithdrawalAmount` | `uint256` | Minimum post-fee withdrawal |
| `feeRecipient` | `address` | Fee collection address |

**Entry Points:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    PUBLIC (Unrestricted)                        │
├─────────────────────────────────────────────────────────────────┤
│ withdrawToL1(address)      │ Legacy P2PKH withdrawal            │
│ withdrawToP2PKH(address)   │ Explicit P2PKH withdrawal          │
│ withdrawToP2SH(address)    │ P2SH (multisig) withdrawal         │
│ withdrawToDogeAddress(str) │ Base58Check decoded withdrawal     │
│ handleL1Message(addr,id)   │ Process verified L1 deposit        │
├─────────────────────────────────────────────────────────────────┤
│                    ADMIN (onlyOwner)                            │
├─────────────────────────────────────────────────────────────────┤
│ initialize(address)        │ Set initial owner                  │
│ updateMessenger(address)   │ Set L2 messenger                   │
│ setWithdrawalFee(uint256)  │ Update withdrawal fee              │
│ setDepositFee(uint256)     │ Update deposit fee                 │
│ setMinWithdrawal(uint256)  │ Update minimum amount              │
│ setFeeRecipient(address)   │ Update fee recipient               │
│ setBascule(address)        │ Update verifier (or disable)       │
│ transferOwnership(address) │ Transfer admin rights              │
│ renounceOwnership()        │ Permanently disable admin          │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 L2DogeOsMessenger (src/dogeos/L2DogeOsMessenger.sol)

**Purpose:** Restricts cross-domain messaging to only the Moat contract

| Property  | Value                                                               |
| --------- | ------------------------------------------------------------------- |
| Inherits  | `L2ScrollMessenger` → `ScrollMessengerBase` → OpenZeppelin upgrades |
| Functions | 47 (including inherited)                                            |
| Features  | Receive ETH, Send ETH, Upgradeable                                  |

**Key Overrides:**

```solidity
// Only Moat can execute incoming L1 messages
_executeMessage(from, to, value, message, hash) {
    require(to == MOAT);  // ← restriction
    super._executeMessage(...);
}

// Only Moat or FeeVault can send outgoing L2 messages
_sendMessage(to, value, message, gasLimit) {
    require(msg.sender == MOAT || msg.sender == FEE_VAULT);  // ← restriction
    super._sendMessage(...);
}
```

### 3.3 DogeAddressLib (src/dogeos/DogeAddressLib.sol)

**Purpose:** Pure library for Base58Check Dogecoin address decoding

| Property   | Value                                  |
| ---------- | -------------------------------------- |
| Type       | Library (inlined, not deployed)        |
| Functions  | 3                                      |
| Complexity | High (assembly for payload extraction) |

**Functions:**

```
decode(string addr) → (bytes1 prefix, bytes20 payload)
    └── Base58Check decode + checksum validation

decodeChecked(string addr, bytes1 p2pkh, bytes1 p2sh) → (bool isP2SH, bytes20 payload)
    └── decode() + prefix validation against network config

_base58CharToValue(uint8 c) → uint8
    └── Character to Base58 value mapping
```

### 3.4 WrappedDoge (src/dogeos/WrappedDoge.sol)

**Purpose:** ERC20 wrapper for native DOGE (like WETH for ETH)

| Property | Value                                      |
| -------- | ------------------------------------------ |
| Inherits | `ERC20Permit` → `ERC20` + `EIP712`         |
| ERCs     | ERC20, ERC2612                             |
| Features | Receive ETH, Send ETH, Ecrecover (permits) |

**Functions:**

```
deposit()   payable  │ Mint WDOGE for DOGE sent
withdraw(uint256)    │ Burn WDOGE and receive DOGE
receive()   payable  │ Auto-deposit when receiving DOGE
```

### 3.5 IBasculeVerifier / BasculeMockVerifier

**Purpose:** Interface and mock for L1 deposit verification

```solidity
interface IBasculeVerifier {
  function validateWithdrawal(
    address _recipient,
    bytes32 _depositID,
    uint256 _withdrawalAmount
  ) external;
}

```

**Mock Behavior:**

- Allows all deposits except `REJECT_DEPOSIT_ID` (for testing)
- **MUST be replaced with real verifier in production**

---

## 4. Data Flows

### 4.1 L2→L1 Withdrawal Flow

```
┌─────────────┐     ┌─────────────┐     ┌──────────────────┐     ┌───────────────┐
│   User      │     │    Moat     │     │ L2DogeOsMessenger│     │ L2MessageQueue│
│  (L2 EOA)   │     │             │     │                  │     │               │
└──────┬──────┘     └──────┬──────┘     └────────┬─────────┘     └───────┬───────┘
       │                   │                     │                       │
       │ withdrawToP2SH()  │                     │                       │
       │ {value: 1 DOGE}   │                     │                       │
       │──────────────────►│                     │                       │
       │                   │                     │                       │
       │                   │ 1. Check fee/min    │                       │
       │                   │ 2. Transfer fee     │                       │
       │                   │    to feeRecipient  │                       │
       │                   │                     │                       │
       │                   │ 3. _encodeEnvelope()│                       │
       │                   │    [0x01, 0x01]     │                       │
       │                   │    (v1, P2SH flag)  │                       │
       │                   │                     │                       │
       │                   │ sendMessage()       │                       │
       │                   │ target=hash160      │                       │
       │                   │ value=amountAfterFee│                       │
       │                   │ message=[0x01,0x01] │                       │
       │                   │────────────────────►│                       │
       │                   │                     │                       │
       │                   │                     │ _sendMessage()        │
       │                   │                     │ (checks sender=MOAT)  │
       │                   │                     │                       │
       │                   │                     │ appendMessage()       │
       │                   │                     │──────────────────────►│
       │                   │                     │                       │
       │                   │                     │                       │ Hash added to
       │                   │                     │                       │ withdrawal root
       │                   │                     │                       │
       │◄──────────────────┤                     │                       │
       │ WithdrawalQueued  │                     │                       │
       │ event emitted     │                     │                       │
```

### 4.2 L1→L2 Deposit Flow

```
┌──────────────┐     ┌───────────────────┐     ┌──────────────────┐     ┌─────────────┐
│ L1 Messenger │     │  L2DogeOsMessenger│     │      Moat        │     │   Target    │
│  (relayer)   │     │                   │     │                  │     │   (user)    │
└──────┬───────┘     └─────────┬─────────┘     └────────┬─────────┘     └──────┬──────┘
       │                       │                        │                      │
       │ relayMessage()        │                        │                      │
       │ to=MOAT               │                        │                      │
       │ message=handleL1Msg() │                        │                      │
       │──────────────────────►│                        │                      │
       │                       │                        │                      │
       │                       │ _executeMessage()      │                      │
       │                       │ (checks _to == MOAT)   │                      │
       │                       │                        │                      │
       │                       │ handleL1Message()      │                      │
       │                       │ {value: depositAmount} │                      │
       │                       │───────────────────────►│                      │
       │                       │                        │                      │
       │                       │                        │ 1. Check caller      │
       │                       │                        │    == messenger      │
       │                       │                        │                      │
       │                       │                        │ 2. basculeVerifier   │
       │                       │                        │    .validateWithdrawal()
       │                       │                        │                      │
       │                       │                        │ 3. Deduct depositFee │
       │                       │                        │    → feeRecipient    │
       │                       │                        │                      │
       │                       │                        │ 4. _target.call()    │
       │                       │                        │    {value: remaining}│
       │                       │                        │─────────────────────►│
       │                       │                        │                      │
       │                       │◄───────────────────────┤                      │
       │◄──────────────────────┤   DepositReceived      │                      │
       │                       │   event emitted        │                      │
```

---

## 5. Message Envelope Format

### 5.1 Envelope Structure

```
┌─────────────┬─────────────┐
│  Version    │   Flags     │
│  (1 byte)   │  (1 byte)   │
└─────────────┴─────────────┘
     0x01         0x00 = P2PKH
                  0x01 = P2SH
```

### 5.2 Version Handling

| Version | Source                 | Flags | Interpretation |
| ------- | ---------------------- | ----- | -------------- |
| 0       | Legacy (empty message) | N/A   | P2PKH          |
| 1       | Current                | 0x00  | P2PKH          |
| 1       | Current                | 0x01  | P2SH           |

---

## 6. Network Configuration

### 6.1 Dogecoin Address Prefixes

| Network | P2PKH | P2SH | Chain ID (L1) |
| ------- | ----- | ---- | ------------- |
| Mainnet | 0x1e  | 0x16 | 1             |
| Testnet | 0x71  | 0xc4 | 111111        |
| Regtest | 0x6f  | 0xc4 | 5555555       |

### 6.2 Deployment Configuration

```solidity
// In DeployScroll.s.sol
function _dogePrefixesFromL1ChainId() private view returns (bytes1 p2pkh, bytes1 p2sh) {
  if (CHAIN_ID_L1 == 1) return (0x1e, 0x16);
  // Mainnet
  else if (CHAIN_ID_L1 == 111_111) return (0x71, 0xc4);
  // Testnet
  else if (CHAIN_ID_L1 == 5_555_555) return (0x6f, 0xc4);
  // Regtest
  else revert("Unknown chain");
}

```

---

## 7. Integration with Scroll

### 7.1 Scroll Components Used

| Component                    | DogeOS Usage                            |
| ---------------------------- | --------------------------------------- |
| `L2ScrollMessenger`          | Base class for `L2DogeOsMessenger`      |
| `ScrollMessengerBase`        | Provides pausing, reentrancy, ownership |
| `L2MessageQueue`             | Stores withdrawal message hashes        |
| `OwnableBase`                | Simplified ownership for `Moat`         |
| `ReentrancyGuardUpgradeable` | Prevents reentrancy in Moat             |

### 7.2 Modified Behavior

| Original Scroll                     | DogeOS Modification                           |
| ----------------------------------- | --------------------------------------------- |
| L2ScrollMessenger allows any sender | L2DogeOsMessenger restricts to MOAT/FEE_VAULT |
| L2ScrollMessenger allows any target | L2DogeOsMessenger restricts to MOAT for L1→L2 |
| Empty message field                 | Used for envelope (version + flags)           |
| ETH as native asset                 | DOGE as native asset                          |

---

## 8. Security Considerations

### 8.1 Access Control Matrix

| Function                | Public | Owner | Messenger |
| ----------------------- | ------ | ----- | --------- |
| `withdrawToP2PKH`       | ✓      |       |           |
| `withdrawToP2SH`        | ✓      |       |           |
| `withdrawToDogeAddress` | ✓      |       |           |
| `handleL1Message`       |        |       | ✓         |
| `setWithdrawalFee`      |        | ✓     |           |
| `setBascule`            |        | ✓     |           |

### 8.2 Reentrancy Protection

All value-transferring functions are protected by `nonReentrant` modifier:

- `withdrawToL1`, `withdrawToP2PKH`, `withdrawToP2SH`, `withdrawToDogeAddress`
- `handleL1Message`

### 8.3 Critical Invariants

1. **Only MOAT can send L2→L1 messages** (enforced by `L2DogeOsMessenger._sendMessage`)
2. **Only MOAT receives L1→L2 messages** (enforced by `L2DogeOsMessenger._executeMessage`)
3. **Fee deduction happens before external calls** (prevents fee griefing)
4. **Network prefixes are immutable** (prevents runtime misconfiguration)

---

## 9. Slither Analysis Summary

| Metric          | Value                   |
| --------------- | ----------------------- |
| Total Contracts | 19 (source) + 21 (deps) |
| Source SLOC     | 990                     |
| High Issues     | 3                       |
| Medium Issues   | 15                      |
| Low Issues      | 14                      |

**DogeOS-Specific Findings:**

- `arbitrary-send-eth` in Moat fee transfers (acceptable - owner-controlled)
- `missing-zero-check` on `_target` in withdrawals (should be fixed)
- Assembly usage in DogeAddressLib (verified correct)

---

## 10. File Reference

| File                                 | Lines | Purpose                          |
| ------------------------------------ | ----- | -------------------------------- |
| `src/dogeos/Moat.sol`                | 328   | Core withdrawal/deposit handling |
| `src/dogeos/DogeAddressLib.sol`      | 166   | Base58Check decoding library     |
| `src/dogeos/L2DogeOsMessenger.sol`   | 104   | Restricted L2 messenger          |
| `src/dogeos/WrappedDoge.sol`         | 47    | WDOGE ERC20 token                |
| `src/dogeos/IBasculeVerifier.sol`    | ~20   | Verifier interface               |
| `src/dogeos/BasculeMockVerifier.sol` | 43    | Mock verifier for testing        |
| `src/dogeos/IMoat.sol`               | ~70   | Moat interface                   |
| `src/dogeos/IL2DogeOsMessenger.sol`  | ~30   | Messenger interface              |
| `src/dogeos/IWDOGE.sol`              | ~10   | WDOGE interface                  |

---

_Generated using Slither 0.11.4 and Trail of Bits methodology_
