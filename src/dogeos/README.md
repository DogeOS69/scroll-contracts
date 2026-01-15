# DogeOS Contracts

Dogecoin-native L2 bridge contracts extending Scroll's messaging infrastructure.

## Contracts

| Contract                                               | Description                                       |
| ------------------------------------------------------ | ------------------------------------------------- |
| [`Moat.sol`](./Moat.sol)                               | Core L2→L1 withdrawals and L1→L2 deposit handling |
| [`L2DogeOsMessenger.sol`](./L2DogeOsMessenger.sol)     | Restricted messenger (only Moat can send/receive) |
| [`DogeAddressLib.sol`](./DogeAddressLib.sol)           | Base58Check Dogecoin address decoding library     |
| [`WrappedDoge.sol`](./WrappedDoge.sol)                 | WDOGE ERC20 token (like WETH)                     |
| [`BasculeMockVerifier.sol`](./BasculeMockVerifier.sol) | Mock deposit verifier (replace in production)     |

## Quick Reference

### Withdrawal Entry Points (Moat)

```solidity
// Direct hash160 payload
withdrawToP2PKH(address target) payable  // Standard addresses (D...)
withdrawToP2SH(address target) payable   // Multisig addresses (A...)

// Full Base58Check address (decoded on-chain)
withdrawToDogeAddress(string dogeAddress) payable
```

### Message Envelope Format

```
[version: 1 byte][flags: 1 byte]
  0x01            0x00 = P2PKH
                  0x01 = P2SH
```

### Network Prefixes (Immutable)

| Network | P2PKH | P2SH |
| ------- | ----- | ---- |
| Mainnet | 0x1e  | 0x16 |
| Testnet | 0x71  | 0xc4 |
| Regtest | 0x6f  | 0xc4 |

## Documentation

Full documentation in [`docs/dogeos/`](../../docs/dogeos/):

- **[ARCHITECTURE.md](../../docs/dogeos/ARCHITECTURE.md)** - Contract hierarchy, data flows, Scroll integration
- **[SPEC.md](../../docs/dogeos/SPEC.md)** - Message envelope specification
- **[SECURITY_REVIEW.md](../../docs/dogeos/SECURITY_REVIEW.md)** - Security audit findings

## Tests

```bash
forge test --match-path "src/test/dogeos/*" -vvv
```
