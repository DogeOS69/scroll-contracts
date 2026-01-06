// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

/**
 * @title DogeAddressLib
 * @notice Library for decoding Base58Check-encoded Dogecoin addresses.
 * @dev Pure functions for decoding and validating Dogecoin P2PKH and P2SH addresses.
 *      This library is designed to be linked/inlined into contracts, not deployed separately.
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

    /**
     * @notice Decode a Base58Check-encoded Dogecoin address.
     * @param addr The Base58Check-encoded address string.
     * @return prefix The version/prefix byte (e.g., 0x1e for mainnet P2PKH).
     * @return payload The 20-byte hash160 payload.
     */
    function decode(string memory addr) internal pure returns (bytes1 prefix, bytes20 payload) {
        bytes memory addrBytes = bytes(addr);
        uint256 len = addrBytes.length;

        // Dogecoin addresses are typically 34 characters but can vary (25-35)
        // Decoded output must be exactly 25 bytes (1 prefix + 20 payload + 4 checksum)
        if (len < 25 || len > 35) {
            revert ErrorInvalidInputLength(25, 35, len);
        }

        // Count leading '1' characters (represent leading zero bytes in output)
        uint256 leadingZeros = 0;
        for (uint256 i = 0; i < len; i++) {
            if (addrBytes[i] == 0x31) {
                // '1' = ASCII 49 = 0x31
                leadingZeros++;
            } else {
                break;
            }
        }

        // Convert Base58 to bytes using big-number arithmetic
        // Maximum output is 25 bytes for a valid address
        bytes memory result = new bytes(25);
        uint256 resultLen = 0;

        for (uint256 i = leadingZeros; i < len; i++) {
            uint8 charValue = _base58CharToValue(uint8(addrBytes[i]));
            if (charValue == 255) {
                revert ErrorInvalidBase58Character(uint8(addrBytes[i]));
            }

            // Multiply result by 58 and add charValue (big-endian, stored right-aligned)
            uint256 carry = charValue;
            for (uint256 j = 0; j < 25; j++) {
                uint256 idx = 24 - j;
                uint256 value = uint256(uint8(result[idx])) * 58 + carry;
                result[idx] = bytes1(uint8(value & 0xFF));
                carry = value >> 8;
            }

            // Track how many bytes are actually used
            for (uint256 j = 0; j < 25; j++) {
                if (result[j] != 0) {
                    resultLen = 25 - j;
                    break;
                }
            }
        }

        // Add leading zeros from '1' characters
        uint256 totalLen = leadingZeros + resultLen;
        if (totalLen != 25) {
            revert ErrorInvalidDecodedLength(25, totalLen);
        }

        // Build the final 25-byte output with leading zeros prepended
        bytes memory decoded = new bytes(25);
        // Leading zeros are already 0x00 in the new bytes array
        // Copy the computed result, right-aligned
        for (uint256 i = 0; i < resultLen; i++) {
            decoded[leadingZeros + i] = result[25 - resultLen + i];
        }

        // Verify checksum: sha256(sha256(prefix + payload)) first 4 bytes
        bytes memory dataToHash = new bytes(21);
        for (uint256 i = 0; i < 21; i++) {
            dataToHash[i] = decoded[i];
        }

        bytes32 hash1 = sha256(dataToHash);
        bytes32 hash2 = sha256(abi.encodePacked(hash1));

        // Compare checksum (last 4 bytes of decoded vs first 4 bytes of hash2)
        if (decoded[21] != hash2[0] || decoded[22] != hash2[1] || decoded[23] != hash2[2] || decoded[24] != hash2[3]) {
            revert ErrorInvalidChecksum();
        }

        // Extract prefix and payload
        prefix = bytes1(decoded[0]);

        // Extract 20-byte payload
        bytes20 payloadBytes;
        assembly {
            // decoded is at position `decoded` in memory
            // bytes memory layout: first 32 bytes = length, then data
            // payload starts at offset 1 (after prefix), so decoded + 32 + 1 = decoded + 33
            payloadBytes := mload(add(decoded, 33))
        }
        payload = payloadBytes;
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
        string memory addr,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix
    ) internal pure returns (bool isP2SH, bytes20 payload) {
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
     * @dev Convert a Base58 character to its numeric value (0-57).
     * @param c The ASCII value of the character.
     * @return The numeric value, or 255 if invalid.
     */
    function _base58CharToValue(uint8 c) private pure returns (uint8) {
        // '1'-'9' (ASCII 49-57) -> 0-8
        if (c >= 49 && c <= 57) return c - 49;
        // 'A'-'H' (ASCII 65-72) -> 9-16
        if (c >= 65 && c <= 72) return c - 56;
        // 'J'-'N' (ASCII 74-78) -> 17-21 (skip 'I' at 73)
        if (c >= 74 && c <= 78) return c - 57;
        // 'P'-'Z' (ASCII 80-90) -> 22-32 (skip 'O' at 79)
        if (c >= 80 && c <= 90) return c - 58;
        // 'a'-'k' (ASCII 97-107) -> 33-43
        if (c >= 97 && c <= 107) return c - 64;
        // 'm'-'z' (ASCII 109-122) -> 44-57 (skip 'l' at 108)
        if (c >= 109 && c <= 122) return c - 65;
        // Invalid character
        return 255;
    }
}
