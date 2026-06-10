#!/usr/bin/env python3
"""Generate Dogecoin signmessage test vectors for DogeSig.sol.

Implements the exact Dogecoin Core `signmessage` algorithm:

    digest = sha256(sha256(
        compactSize(len(magic)) || magic || compactSize(len(message)) || message
    ))
    sig65 = compact_ecdsa_sign(digest)        # header || r || s
    header = 27 + recId + (4 if compressed else 0)
    keyHash = ripemd160(sha256(serialized_pubkey))

and writes src/test/dogeos/DogeSigTestVectors.sol (plain Solidity, no test-framework
imports; the file is compiled by both Foundry and Hardhat).

Usage:
    pip install -r scripts/dogeos/requirements.txt
    python3 scripts/dogeos/gen_doge_sig_vectors.py

Signing uses coincurve (libsecp256k1, the same library Dogecoin Core links against)
with RFC6979 deterministic nonces, so regeneration is byte-identical.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

from coincurve import PrivateKey, PublicKey

REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_PATH = REPO_ROOT / "src" / "test" / "dogeos" / "DogeSigTestVectors.sol"

MESSAGE_MAGIC = b"Dogecoin Signed Message:\n"
SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141


# --- RIPEMD-160 (pure-Python fallback for OpenSSL 3.x without the legacy provider) --- #

def _ripemd160_pure(data: bytes) -> bytes:
    """Pure-Python RIPEMD-160 (public-domain algorithm, RIPEMD-160 spec)."""

    def rol(x: int, n: int) -> int:
        return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF

    # fmt: off
    R1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
          7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
          3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
          1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
          4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13]
    R2 = [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
          6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
          15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
          8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
          12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11]
    S1 = [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
          7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
          11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
          11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
          9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6]
    S2 = [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
          9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
          9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
          15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
          8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11]
    K1 = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
    K2 = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]
    # fmt: on

    def f(j: int, x: int, y: int, z: int) -> int:
        if j < 16:
            return x ^ y ^ z
        if j < 32:
            return (x & y) | (~x & z)
        if j < 48:
            return (x | ~y) ^ z
        if j < 64:
            return (x & z) | (y & ~z)
        return x ^ (y | ~z)

    msg = bytearray(data)
    bitlen = len(msg) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    msg += struct.pack("<Q", bitlen)

    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    for block_ofs in range(0, len(msg), 64):
        x = struct.unpack("<16I", bytes(msg[block_ofs : block_ofs + 64]))
        a, b, c, d, e = h
        a2, b2, c2, d2, e2 = h
        for j in range(80):
            t = (rol((a + f(j, b, c, d) + x[R1[j]] + K1[j // 16]) & 0xFFFFFFFF, S1[j]) + e) & 0xFFFFFFFF
            a, e, d, c, b = e, d, rol(c, 10), b, t
            t = (rol((a2 + f(79 - j, b2, c2, d2) + x[R2[j]] + K2[j // 16]) & 0xFFFFFFFF, S2[j]) + e2) & 0xFFFFFFFF
            a2, e2, d2, c2, b2 = e2, d2, rol(c2, 10), b2, t
        t = (h[1] + c + d2) & 0xFFFFFFFF
        h[1] = (h[2] + d + e2) & 0xFFFFFFFF
        h[2] = (h[3] + e + a2) & 0xFFFFFFFF
        h[3] = (h[4] + a + b2) & 0xFFFFFFFF
        h[4] = (h[0] + b + c2) & 0xFFFFFFFF
        h[0] = t
    return struct.pack("<5I", *h)


def ripemd160(data: bytes) -> bytes:
    try:
        return hashlib.new("ripemd160", data).digest()
    except (ValueError, TypeError):
        return _ripemd160_pure(data)


def _ripemd160_self_test() -> None:
    """Known-answer tests, run at import time.

    The pure-Python fallback is exercised unconditionally (it only runs in production
    when OpenSSL lacks the legacy provider, so without this it would be dead untested
    code), and whichever implementation `ripemd160()` dispatches to is checked too.
    """
    kats = {
        b"": bytes.fromhex("9c1185a5c5e9fc54612808977ee8f548b2258d31"),
        b"abc": bytes.fromhex("8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"),
        b"message digest": bytes.fromhex("5d0689ef49d2fae572b881b123a85ffa21595f36"),
    }
    for msg, want in kats.items():
        got = _ripemd160_pure(msg)
        if got != want:
            raise RuntimeError(f"pure-Python RIPEMD-160 KAT failed for {msg!r}: {got.hex()}")
        got = ripemd160(msg)
        if got != want:
            raise RuntimeError(f"ripemd160() dispatch KAT failed for {msg!r}: {got.hex()}")


_ripemd160_self_test()


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


# --- Dogecoin signmessage --- #

def compact_size(n: int) -> bytes:
    if n < 0xFD:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    if n <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", n)
    return b"\xff" + struct.pack("<Q", n)


def message_hash(message: bytes) -> bytes:
    serialized = compact_size(len(MESSAGE_MAGIC)) + MESSAGE_MAGIC + compact_size(len(message)) + message
    return sha256(sha256(serialized))


def hash160(data: bytes) -> bytes:
    return ripemd160(sha256(data))


@dataclass
class Vector:
    name: str
    privkey: int
    message: bytes
    compressed: bool
    expected_rec_id: int

    def build(self) -> dict:
        priv = PrivateKey(self.privkey.to_bytes(32, "big"))
        pub = PublicKey.from_secret(priv.secret)
        x, y = pub.point()

        digest = message_hash(self.message)
        # coincurve returns r(32) || s(32) || recId(1); hasher=None signs the raw digest.
        sig = priv.sign_recoverable(digest, hasher=None)
        # plain raises (not assert): asserts vanish under `python -O`
        if len(sig) != 65:
            raise RuntimeError(f"vector {self.name!r}: unexpected signature length {len(sig)}")
        r, s, rec_id = sig[:32], sig[32:64], sig[64]

        if rec_id != self.expected_rec_id:
            raise RuntimeError(
                f"vector {self.name!r}: recId {rec_id}, expected {self.expected_rec_id}; "
                "tweak the key or message constant"
            )
        if int.from_bytes(s, "big") > SECP256K1_N // 2:
            raise RuntimeError(f"vector {self.name!r}: high-s output; libsecp256k1 should sign low-s")

        # Self-check: recover the pubkey from the compact signature.
        recovered = PublicKey.from_signature_and_message(sig, digest, hasher=None)
        if recovered.format(compressed=False) != pub.format(compressed=False):
            raise RuntimeError(f"vector {self.name!r}: pubkey recovery self-check failed")

        header = 27 + rec_id + (4 if self.compressed else 0)
        serialized_pub = pub.format(compressed=self.compressed)
        key_hash = hash160(serialized_pub)

        return {
            "name": self.name,
            "message": self.message,
            "msgHash": digest,
            "header": header,
            "r": r,
            "s": s,
            "x": x.to_bytes(32, "big"),
            "y": y.to_bytes(32, "big"),
            "keyHash": key_hash,
            "compressed": self.compressed,
        }


# Fixed private keys: small constants so regeneration is trivially deterministic.
# expected_rec_id values were observed once and are asserted on every regeneration.
VECTORS = [
    Vector("compressed short ascii", 0x01, b"Such verify. Much wow.", True, 1),
    Vector("uncompressed short ascii", 0x02, b"Such verify. Much wow.", False, 1),
    Vector("empty message", 0x03, b"", True, 1),
    Vector("raw 32-byte intent hash", 0x04, bytes(range(212, 244)), True, 1),
    Vector("message length 252", 0x05, b"d" * 252, True, 0),
    Vector("message length 253", 0x06, b"o" * 253, True, 1),
    Vector("message length 1024", 0x07, b"g" * 1024, True, 0),
    Vector("recId zero", 0x08, b"recovery id zero", True, 0),
    Vector("recId one", 0x09, b"recovery id one!", True, 1),
    # header 27: uncompressed + recId 0 completes the header matrix (27/28/31/32)
    Vector("uncompressed recId zero", 0x0B, b"uncompressed recovery id zero", False, 0),
]


def sol_bytes_literal(data: bytes) -> str:
    if not data:
        return 'hex""'
    return f'hex"{data.hex()}"'


def emit(vectors: list[dict]) -> str:
    lines = [
        "// SPDX-License-Identifier: MIT",
        "",
        "pragma solidity =0.8.24;",
        "",
        "// GENERATED FILE - DO NOT EDIT.",
        "// Regenerate: python3 scripts/dogeos/gen_doge_sig_vectors.py",
        "//   (deps: pip install -r scripts/dogeos/requirements.txt)",
        "// Plain Solidity only - this file is compiled by both Foundry and Hardhat.",
        "",
        "/**",
        " * @title DogeSigTestVectors",
        " * @notice Dogecoin Core-compatible signmessage test vectors for DogeSig.",
        " * @dev Generated with coincurve (libsecp256k1, RFC6979 deterministic nonces).",
        " */",
        "abstract contract DogeSigTestVectors {",
        "    struct SigVector {",
        "        string name;",
        "        bytes message;",
        "        bytes32 msgHash;",
        "        uint8 header;",
        "        bytes32 r;",
        "        bytes32 s;",
        "        bytes32 x;",
        "        bytes32 y;",
        "        bytes20 keyHash;",
        "        bool compressed;",
        "    }",
        "",
        "    function _sigVectors() internal pure returns (SigVector[] memory vectors) {",
        f"        vectors = new SigVector[]({len(vectors)});",
    ]
    for i, v in enumerate(vectors):
        msg = v["message"]
        if len(msg) > 64 and len(set(msg)) == 1:
            ch = msg[0]
            msg_expr = f'_repeat(bytes1(0x{ch:02x}), {len(msg)})'
        else:
            msg_expr = sol_bytes_literal(msg)
        lines += [
            f"        // {v['name']} (recId {(v['header'] - 27) & 3})",
            f"        vectors[{i}] = SigVector({{",
            f'            name: "{v["name"]}",',
            f"            message: {msg_expr},",
            f"            msgHash: bytes32(0x{v['msgHash'].hex()}),",
            f"            header: {v['header']},",
            f"            r: bytes32(0x{v['r'].hex()}),",
            f"            s: bytes32(0x{v['s'].hex()}),",
            f"            x: bytes32(0x{v['x'].hex()}),",
            f"            y: bytes32(0x{v['y'].hex()}),",
            # hex string literal (not 0x...) to avoid the address checksum syntax error
            f'            keyHash: hex"{v["keyHash"].hex()}",',
            f"            compressed: {'true' if v['compressed'] else 'false'}",
            "        });",
        ]
    lines += [
        "        return vectors;",
        "    }",
        "",
        "    function _repeat(bytes1 char, uint256 len) private pure returns (bytes memory out) {",
        "        out = new bytes(len);",
        "        for (uint256 i = 0; i < len; i++) {",
        "            out[i] = char;",
        "        }",
        "    }",
        "}",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    built = [v.build() for v in VECTORS]
    OUTPUT_PATH.write_text(emit(built))
    print(f"wrote {OUTPUT_PATH} ({len(built)} vectors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
