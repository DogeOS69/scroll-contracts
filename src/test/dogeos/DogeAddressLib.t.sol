// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {DogeAddressLib} from "../../dogeos/DogeAddressLib.sol";
import {ReferenceDogeAddressLib} from "./reference/ReferenceDogeAddressLib.sol";

/// @dev Exposes the optimized decoder and the frozen reference decoder side by side.
contract DogeAddressDecoderHarness {
    function decodeNew(string calldata addr) external view returns (bytes1 prefix, bytes20 payload) {
        return DogeAddressLib.decode(addr);
    }

    function decodeReference(string calldata addr) external pure returns (bytes1 prefix, bytes20 payload) {
        return ReferenceDogeAddressLib.decode(addr);
    }

    function decodeCheckedNew(
        string calldata addr,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix
    ) external view returns (bool isP2SH, bytes20 payload) {
        return DogeAddressLib.decodeChecked(addr, p2pkhPrefix, p2shPrefix);
    }

    function decodeCheckedReference(
        string calldata addr,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix
    ) external pure returns (bool isP2SH, bytes20 payload) {
        return ReferenceDogeAddressLib.decodeChecked(addr, p2pkhPrefix, p2shPrefix);
    }

    function gasNew(string calldata addr) external view returns (uint256 used) {
        uint256 start = gasleft();
        DogeAddressLib.decode(addr);
        used = start - gasleft();
    }

    function gasReference(string calldata addr) external view returns (uint256 used) {
        uint256 start = gasleft();
        ReferenceDogeAddressLib.decode(addr);
        used = start - gasleft();
    }
}

/// @notice Differential and round-trip tests for the uint256-accumulator Base58Check
///         decoder against the frozen byte-array implementation it replaced. Every
///         comparison checks success AND the exact return/revert bytes, so error
///         selectors and arguments must match too.
contract DogeAddressLibTest is Test {
    bytes internal constant ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    bytes20 internal constant PAYLOAD_89AB = bytes20(0x89aBCDeF89ABCDEf89aBCDEF89aBcdEF89ABcdeF);

    DogeAddressDecoderHarness internal _h;

    function setUp() public {
        _h = new DogeAddressDecoderHarness();
    }

    // --- Encoder (test-only reference) --- //

    /// @dev Base58 digits of `v`, preceded by `leadingOnes` '1' characters.
    function _toBase58(uint256 v, uint256 leadingOnes) internal pure returns (bytes memory out) {
        bytes memory alphabet = ALPHABET;
        bytes memory digits = new bytes(50);
        uint256 n;
        while (v > 0) {
            digits[n++] = alphabet[v % 58];
            v /= 58;
        }
        out = new bytes(leadingOnes + n);
        for (uint256 i = 0; i < leadingOnes; i++) {
            out[i] = "1";
        }
        for (uint256 i = 0; i < n; i++) {
            out[leadingOnes + i] = digits[n - 1 - i];
        }
    }

    /// @dev Canonical Base58Check encoding of prefix || payload || checksum.
    function _encode(bytes1 prefix, bytes20 payload) internal pure returns (bytes memory) {
        bytes memory data = abi.encodePacked(prefix, payload);
        bytes4 checksum = bytes4(sha256(abi.encodePacked(sha256(data))));
        uint256 v = (uint256(uint8(prefix)) << 192) | (uint256(uint160(payload)) << 32) | uint256(uint32(checksum));
        uint256 zeros;
        while (zeros < 25 && (v >> (8 * (24 - zeros))) & 0xff == 0) {
            zeros++;
        }
        return _toBase58(v, zeros);
    }

    // --- Differential assertions --- //

    function _assertSameDecode(bytes memory s) internal {
        (bool okNew, bytes memory retNew) = address(_h).staticcall(
            abi.encodeCall(DogeAddressDecoderHarness.decodeNew, (string(s)))
        );
        (bool okReference, bytes memory retReference) = address(_h).staticcall(
            abi.encodeCall(DogeAddressDecoderHarness.decodeReference, (string(s)))
        );
        assertEq(okNew, okReference, string.concat("success mismatch for: ", string(s)));
        assertEq(retNew, retReference, string.concat("return/revert data mismatch for: ", string(s)));
    }

    function _assertSameDecodeChecked(
        bytes memory s,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix
    ) internal {
        (bool okNew, bytes memory retNew) = address(_h).staticcall(
            abi.encodeCall(DogeAddressDecoderHarness.decodeCheckedNew, (string(s), p2pkhPrefix, p2shPrefix))
        );
        (bool okReference, bytes memory retReference) = address(_h).staticcall(
            abi.encodeCall(DogeAddressDecoderHarness.decodeCheckedReference, (string(s), p2pkhPrefix, p2shPrefix))
        );
        assertEq(okNew, okReference, "decodeChecked success mismatch");
        assertEq(retNew, retReference, "decodeChecked return/revert data mismatch");
    }

    function _assertRoundTrip(bytes1 prefix, bytes20 payload) internal {
        bytes memory s = _encode(prefix, payload);
        (bytes1 gotPrefix, bytes20 gotPayload) = _h.decodeNew(string(s));
        assertEq(gotPrefix, prefix, "prefix round trip");
        assertEq(gotPayload, payload, "payload round trip");
        _assertSameDecode(s);
    }

    // --- Encoder sanity (the encoder is independent of both decoders) --- //

    function test_EncoderMatchesKnownVectors() external {
        assertEq(string(_encode(0x1e, PAYLOAD_89AB)), "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz");
        assertEq(
            string(_encode(0x16, bytes20(0x0123456789012345678901234567890123456789))),
            "9rYHbG7NUbMEX7jEGCXeHVZ7RiowPFZPPN"
        );
        assertEq(string(_encode(0x71, PAYLOAD_89AB)), "ngk6ejVecZ9Y7aLGQhKUL7JPBUVVdeoBmd");
        assertEq(string(_encode(0xc4, PAYLOAD_89AB)), "2N5oANkEZYXcFzYuTSWxvaWtgRLsngz5GBG");
        assertEq(string(_encode(0x00, PAYLOAD_89AB)), "1DYwPTp6PAnXhbaUeHgTXwYV4UNuN85ZJw");
        assertEq(
            string(_encode(0x1e, bytes20(0x0000000000000000000000000000000000000001))),
            "D596YFweJQuHY1BbjazZYmAbt8jJXaDhSF"
        );
    }

    // --- Deterministic differential cases --- //

    function test_KnownInputs_MatchReference() external {
        string[24] memory inputs = [
            "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz", // mainnet P2PKH
            "9rYHbG7NUbMEX7jEGCXeHVZ7RiowPFZPPN", // mainnet P2SH
            "ngk6ejVecZ9Y7aLGQhKUL7JPBUVVdeoBmd", // testnet P2PKH
            "2N5oANkEZYXcFzYuTSWxvaWtgRLsngz5GBG", // testnet P2SH, 35 chars
            "1DYwPTp6PAnXhbaUeHgTXwYV4UNuN85ZJw", // prefix 0x00 (leading '1')
            "D596YFweJQuHY1BbjazZYmAbt8jJXaDhSF", // near-zero payload
            "2zJDSzX4VSmK7bZTFeGwcDoPV4k4gftvWxG", // canonical value + 2^200 (overflow alias)
            "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFy1", // bad checksum
            "DOgecoinIsGreat12345678901234", // invalid 'O'
            "D0gecoinIsGreat12345678901234", // invalid '0'
            "Dlgecoin12345678901234567890123", // invalid 'l'
            "DShortAddr", // too short
            "DThisAddressIsWayTooLongToBeAValidDogeAddress12789", // too long
            "1111111111111111111111111", // 25 x '1': all-zero bytes, bad checksum
            "11111111111111111111111111", // 26 x '1': decoded length 26
            "111111111111111111111111111111111111", // 36 x '1': too long
            "11DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz", // extra leading '1's on a valid address
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", // 35 x 'z': overflow
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", // 33 x 'z': fits, wrong decoded length
            "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyzO", // valid address followed by an invalid char
            "O2zJDSzX4VSmK7bZTFeGwcDoPV4k4gftvWx", // bad char first
            "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFy", // truncated valid address
            "2222222222222222222222222", // 25 chars, too few bytes
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" // NULs
        ];
        for (uint256 i = 0; i < inputs.length; i++) {
            _assertSameDecode(bytes(inputs[i]));
        }
    }

    /// @dev Every byte value in the first, middle, and last position is classified
    ///      (valid digit vs ErrorInvalidBase58Character) exactly like the reference decoder.
    function test_AllByteValues_ClassifiedLikeReference() external {
        for (uint256 b = 0; b < 256; b++) {
            for (uint256 pos = 0; pos < 3; pos++) {
                bytes memory s = bytes("zzzzzzzzzzzzzzzzzzzzzzzzz"); // 25 chars
                s[pos == 0 ? 0 : (pos == 1 ? 12 : 24)] = bytes1(uint8(b));
                _assertSameDecode(s);
            }
        }
    }

    function test_RoundTrip_DeterministicSweep() external {
        bytes1[8] memory prefixes = [bytes1(0x00), 0x05, 0x16, 0x1e, 0x6f, 0x71, 0xc4, 0xff];
        for (uint256 p = 0; p < prefixes.length; p++) {
            _assertRoundTrip(prefixes[p], bytes20(0));
            _assertRoundTrip(prefixes[p], bytes20(type(uint160).max));
            for (uint256 i = 0; i < 24; i++) {
                bytes20 payload = bytes20(keccak256(abi.encode(i, prefixes[p])));
                // Also exercise payloads with leading zero bytes (shorter encodings).
                _assertRoundTrip(prefixes[p], payload);
                _assertRoundTrip(prefixes[p], bytes20(uint160(payload) >> (8 * (i % 20))));
            }
        }
    }

    // --- Fuzzed differential cases --- //

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_RoundTrip(
        bytes1 prefix,
        bytes20 payload,
        uint8 shift
    ) external {
        _assertRoundTrip(prefix, payload);
        // Payloads with leading zero bytes.
        _assertRoundTrip(prefix, bytes20(uint160(payload) >> (8 * (shift % 21))));
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_Differential_MutatedValid(
        bytes1 prefix,
        bytes20 payload,
        uint8 op,
        uint256 pos,
        uint8 ch
    ) external {
        bytes memory s = _encode(prefix, payload);
        bytes memory alphabet = ALPHABET;
        op = op % 6;
        if (op == 0) {
            s[pos % s.length] = bytes1(ch); // replace with an arbitrary byte
        } else if (op == 1) {
            s[pos % s.length] = alphabet[ch % 58]; // replace with another digit
        } else if (op == 2) {
            // insert a digit
            uint256 at = pos % (s.length + 1);
            bytes memory t = new bytes(s.length + 1);
            for (uint256 i = 0; i < t.length; i++) {
                t[i] = i < at ? s[i] : (i == at ? alphabet[ch % 58] : s[i - 1]);
            }
            s = t;
        } else if (op == 3) {
            // delete a character
            uint256 at = pos % s.length;
            bytes memory t = new bytes(s.length - 1);
            for (uint256 i = 0; i < t.length; i++) {
                t[i] = i < at ? s[i] : s[i + 1];
            }
            s = t;
        } else if (op == 4) {
            s = abi.encodePacked("1", s); // extra leading zero digit
        } else {
            s = abi.encodePacked(s, alphabet[ch % 58]); // append a digit
        }
        _assertSameDecode(s);
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_Differential_AlphabetStrings(
        uint256 seed,
        uint8 lenSeed,
        uint8 onesSeed
    ) external {
        bytes memory alphabet = ALPHABET;
        uint256 ones = onesSeed % 4;
        uint256 len = 22 + (lenSeed % 17); // 22..38 digits after the leading '1's
        bytes memory s = new bytes(ones + len);
        for (uint256 i = 0; i < ones; i++) {
            s[i] = "1";
        }
        for (uint256 i = 0; i < len; i++) {
            s[ones + i] = alphabet[uint256(keccak256(abi.encode(seed, i))) % 58];
        }
        _assertSameDecode(s);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_Differential_ArbitraryBytes(bytes calldata raw) external {
        _assertSameDecode(raw);
    }

    /// @dev Values straddling the 2^200 canonical bound, with 0-3 leading '1's.
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_Differential_NearOverflowBoundary(
        uint64 delta,
        bool above,
        uint8 ones
    ) external {
        uint256 v = above ? (uint256(1) << 200) + delta : (uint256(1) << 200) - 1 - delta;
        _assertSameDecode(_toBase58(v, ones % 4));
    }

    /// @dev Arbitrary values up to 2^206 (covers every decoded-length outcome).
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_Differential_RandomValues(uint256 v, uint8 ones) external {
        _assertSameDecode(_toBase58(v >> 50, ones % 4));
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_Differential_DecodeChecked(
        bytes1 prefix,
        bytes20 payload,
        bytes1 p2pkhPrefix,
        bytes1 p2shPrefix,
        uint8 pick
    ) external {
        // Bias toward configured prefixes so both accepting branches are exercised.
        if (pick % 3 == 0) prefix = p2pkhPrefix;
        else if (pick % 3 == 1) prefix = p2shPrefix;
        _assertSameDecodeChecked(_encode(prefix, payload), p2pkhPrefix, p2shPrefix);
    }

    // --- Gas --- //

    function test_Gas_DecodeComparedToReference() external {
        string[3] memory inputs = [
            "DHh2vikjgagpEbm5Nsg25hi5wc7CfwbFyz", // 34 chars
            "2N5oANkEZYXcFzYuTSWxvaWtgRLsngz5GBG", // 35 chars
            "1DYwPTp6PAnXhbaUeHgTXwYV4UNuN85ZJw" // leading '1'
        ];
        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 gasNew = _h.gasNew(inputs[i]);
            uint256 gasReference = _h.gasReference(inputs[i]);
            console2.log(inputs[i]);
            console2.log("  new decode gas:      ", gasNew);
            console2.log("  reference decode gas:", gasReference);
            assertLt(gasNew, 10_000, "optimized decode should stay under 10k gas");
        }
    }
}
