// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

// solhint-disable no-inline-assembly, no-empty-blocks

/**
 * @title DogeAddressLib
 * @notice Library for decoding Base58Check-encoded Dogecoin addresses.
 * @dev Internal functions only, so the compiler inlines them into the calling contract:
 *      there is no separate library deployment and no DELEGATECALL.
 *
 *      A valid address decodes to exactly 25 bytes (1 prefix + 20 payload + 4 checksum),
 *      which is a 200-bit integer. The whole Base58 value is therefore accumulated in a
 *      single uint256 word instead of a byte array, in one pass over the calldata.
 */
library DogeAddressLib {
    // --- Errors --- //
    error ErrorInvalidBase58Character(uint8 char);
    error ErrorInvalidInputLength(uint256 minLength, uint256 maxLength, uint256 actual);
    error ErrorInvalidDecodedLength(uint256 expected, uint256 actual);
    error ErrorInvalidChecksum();
    error ErrorUnrecognizedPrefix(bytes1 prefix);

    // Base58 alphabet: 123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
    // Excludes: 0, O, I, l (zero, capital o, capital i, lowercase L)

    /// @dev Base58 digit lookup table for ASCII 0x20-0x7f, one byte per character: the digit
    ///      value (0-57), or 0xff for a character outside the alphabet. ASCII 0x00-0x1f is
    ///      all 0xff and is written as not(0); bytes >= 0x80 are rejected by their high bit.
    uint256 private constant TABLE_20 = 0xffffffffffffffffffffffffffffffffff000102030405060708ffffffffffff;
    uint256 private constant TABLE_40 = 0xff090a0b0c0d0e0f10ff1112131415ff161718191a1b1c1d1e1f20ffffffffff;
    uint256 private constant TABLE_60 = 0xff2122232425262728292a2bff2c2d2e2f30313233343536373839ffffffffff;

    /// @dev Sentinel for "no invalid character seen" (outside the uint8 range).
    uint256 private constant NO_BAD_CHAR = 0x100;

    /**
     * @notice Decode a Base58Check-encoded Dogecoin address.
     * @dev Checks, in this order: length within [25, 35]; every character in the Base58
     *      alphabet (the first invalid one is reported); value fits in 25 bytes (otherwise a
     *      non-canonical alias, reported as decoded length 26); total decoded length (leading
     *      '1's plus value bytes) exactly 25; double-SHA256 checksum. Accepts and rejects
     *      exactly the same inputs, with the same errors, as the previous byte-array decoder,
     *      which is pinned in src/test/dogeos/reference/ and differentially tested in
     *      src/test/dogeos/DogeAddressLib.t.sol.
     * @param addr The Base58Check-encoded address string.
     * @return prefix The version/prefix byte (e.g., 0x1e for mainnet P2PKH).
     * @return payload The 20-byte hash160 payload.
     */
    function decode(string calldata addr) internal view returns (bytes1 prefix, bytes20 payload) {
        uint256 len = bytes(addr).length;

        // Dogecoin addresses are typically 34 characters but can vary (25-35)
        if (len < 25 || len > 35) {
            revert ErrorInvalidInputLength(25, 35, len);
        }

        uint256 leadingZeros;
        uint256 value;
        uint256 badChar = NO_BAD_CHAR;

        assembly {
            let start := addr.offset
            let end := add(start, len)
            let ptr := start

            // Leading '1' characters (0x31) each encode one leading zero byte.
            for {

            } and(lt(ptr, end), eq(byte(0, calldataload(ptr)), 0x31)) {
                ptr := add(ptr, 1)
            } {

            }
            leadingZeros := sub(ptr, start)

            // Place the lookup table in unallocated memory at the free memory pointer. It is
            // only read inside this block, so the free memory pointer is left unchanged.
            let table := mload(0x40)
            mstore(table, not(0))
            mstore(add(table, 0x20), TABLE_20)
            mstore(add(table, 0x40), TABLE_40)
            mstore(add(table, 0x60), TABLE_60)

            // Branch-free main loop. Valid characters are <= 0x7a and valid digits <= 57,
            // so or(c, digit) stays below 0x80 for them. An 0xff table entry or a byte
            // >= 0x80 sets bit 7 of `bad`. Once bit 7 is set, `value` is garbage and is
            // never used.
            let bad := 0
            for {

            } lt(ptr, end) {
                ptr := add(ptr, 1)
            } {
                let c := byte(0, calldataload(ptr))
                let digit := byte(0, mload(add(table, c)))
                bad := or(bad, or(c, digit))
                value := add(mul(value, 58), digit)
            }

            // Error path only: report the first invalid character, as a sequential decoder would.
            if and(bad, 0x80) {
                for {
                    ptr := start
                } lt(ptr, end) {
                    ptr := add(ptr, 1)
                } {
                    let c := byte(0, calldataload(ptr))
                    if or(gt(c, 0x7f), eq(byte(0, mload(add(table, c))), 0xff)) {
                        badChar := c
                        break
                    }
                }
            }
        }

        if (badChar != NO_BAD_CHAR) {
            revert ErrorInvalidBase58Character(uint8(badChar));
        }

        // A value that no longer fits in 25 bytes would, if truncated, alias a valid address
        // (same low 25 bytes, valid checksum), so reject it. Since 58^34 < 2^200, only the
        // 35th Base58 digit can cross the bound, so a single check after the loop matches a
        // per-digit check. With at most 35 digits, value < 58^35 < 2^206, so the uint256
        // accumulator cannot wrap for valid input.
        if (value >> 200 != 0) {
            revert ErrorInvalidDecodedLength(25, 26);
        }

        // Decoded output must be exactly 25 bytes (1 prefix + 20 payload + 4 checksum)
        uint256 totalLen = leadingZeros + _byteLength(value);
        if (totalLen != 25) {
            revert ErrorInvalidDecodedLength(25, totalLen);
        }

        // value is now the 25 decoded bytes as a big-endian integer:
        // prefix (bits 192..199) || payload (bits 32..191) || checksum (bits 0..31).
        // Verify checksum: sha256(sha256(prefix + payload)) first 4 bytes. The precompile is
        // called directly in scratch space (about 850 gas cheaper than the sha256 builtin, which
        // allocates memory), which is why this library is `view` rather than `pure`.
        bool checksumOk;
        assembly {
            // prefix || payload (21 bytes), left-aligned in the scratch word.
            mstore(0x00, shl(88, shr(32, value)))
            // The sha256 precompile (0x02) only fails when out of gas.
            if iszero(staticcall(gas(), 0x02, 0x00, 21, 0x00, 0x20)) {
                revert(0, 0)
            }
            if iszero(staticcall(gas(), 0x02, 0x00, 0x20, 0x00, 0x20)) {
                revert(0, 0)
            }
            checksumOk := eq(shr(224, mload(0x00)), and(value, 0xffffffff))
        }
        if (!checksumOk) {
            revert ErrorInvalidChecksum();
        }

        prefix = bytes1(uint8(value >> 192));
        payload = bytes20(uint160(value >> 32));
    }

    /**
     * @notice Decode and validate against configured network prefixes.
     * @param addr The Base58Check-encoded address string.
     * @param p2pkhPrefix The expected P2PKH prefix for this network.
     * @param p2shPrefix The expected P2SH prefix for this network.
     * @return isP2SH True if the address is P2SH, false if P2PKH.
     * @return payload The 20-byte hash160 payload.
     */
    function decodeChecked(
        string calldata addr,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix
    ) internal view returns (bool isP2SH, bytes20 payload) {
        bytes1 prefix;
        (prefix, payload) = decode(addr);

        if (prefix == p2pkhPrefix) {
            isP2SH = false;
        } else if (prefix == p2shPrefix) {
            isP2SH = true;
        } else {
            revert ErrorUnrecognizedPrefix(prefix);
        }
    }

    /**
     * @dev Number of significant bytes in `x` (0 for x == 0).
     * @param x The value to measure.
     * @return n The byte length of `x`.
     */
    function _byteLength(uint256 x) private pure returns (uint256 n) {
        if (x >> 128 != 0) {
            x >>= 128;
            n = 16;
        }
        if (x >> 64 != 0) {
            x >>= 64;
            n += 8;
        }
        if (x >> 32 != 0) {
            x >>= 32;
            n += 4;
        }
        if (x >> 16 != 0) {
            x >>= 16;
            n += 2;
        }
        if (x >> 8 != 0) {
            x >>= 8;
            n += 1;
        }
        if (x != 0) {
            n += 1;
        }
    }
}
