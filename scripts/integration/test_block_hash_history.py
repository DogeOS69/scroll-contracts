"""Regression tests for snapshot consistency in the read-only RPC smoke check."""

import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "history_smoke", Path(__file__).resolve().parents[1] / "check-block-hash-history.py"
)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class ChainRPC:
    def __init__(self, height, activation=1, fork=0):
        self.height = height
        self.activation = activation
        self.fork = fork
        self.calls = []
        self.selected_reads = 0
        self.reorg_at_end = False
        self.foreign_history = False
        self.reject_snapshot = False

    def block_hash(self, number):
        return "0x" + (self.fork * 100000 + number + 1).to_bytes(32, "big").hex()

    def header(self, number):
        return {
            "hash": self.block_hash(number),
            "parentHash": self.block_hash(number - 1),
            "stateRoot": "0x" + (self.fork + 20).to_bytes(32, "big").hex(),
        }

    def history(self, number):
        if self.foreign_history:
            return "0x" + "ff" * 32
        return self.block_hash(number) if number >= self.activation - 1 else smoke.ZERO

    def __call__(self, url, method, params):
        self.calls.append((method, params))
        if method == "eth_getBlockByNumber":
            number = int(params[0], 16)
            header = self.header(number)
            if number == self.height:
                self.selected_reads += 1
                if self.reorg_at_end and self.selected_reads > 1:
                    header["hash"] = "0x" + "ee" * 32
            return header
        expected_snapshot = {"blockHash": self.block_hash(self.height), "requireCanonical": True}
        if params[-1] != expected_snapshot:
            raise AssertionError(f"state query was not pinned to the canonical snapshot: {params}")
        if self.reject_snapshot:
            raise RuntimeError("RPC rejected blockHash/requireCanonical")
        if method == "eth_getCode":
            return smoke.CODE
        if method == "eth_getTransactionCount":
            return "0x1"
        if method == "eth_call":
            return self.history(int(params[0]["data"], 16))
        if method == "eth_getStorageAt":
            slot = int(params[1], 16)
            number = self.height - 1 - (self.height - 1 - slot) % smoke.WINDOW
            return self.history(number)
        raise AssertionError(method)


class SnapshotTests(unittest.TestCase):
    def test_reads_share_one_canonical_snapshot(self):
        for height, activation in [(1, 1), (2, 1), (8192, 1), (100, 100), (101, 100)]:
            with self.subTest(height=height, activation=activation):
                chain = ChainRPC(height, activation)
                with patch.object(smoke, "rpc", chain):
                    result = smoke.check("test", height, activation)
                self.assertEqual(result, (chain.header(height)["hash"], chain.header(height)["stateRoot"]))
                self.assertEqual(chain.selected_reads, 2)
                self.assertTrue(any(method == "eth_getStorageAt" for method, _ in chain.calls))
                # The parent must come from the selected header, not a mutable
                # numbered lookup that could already belong to a different chain.
                self.assertFalse(any(
                    method == "eth_getBlockByNumber" and params[0] == hex(height - 1)
                    for method, params in chain.calls
                ))

    def test_foreign_history_cannot_pass_with_original_header(self):
        chain = ChainRPC(1)
        chain.foreign_history = True
        with patch.object(smoke, "rpc", chain), self.assertRaisesRegex(RuntimeError, "does not match"):
            smoke.check("test", 1, 1)

    def test_replaced_canonical_block_cannot_report_success(self):
        chain = ChainRPC(8192)
        chain.reorg_at_end = True
        with patch.object(smoke, "rpc", chain), self.assertRaisesRegex(RuntimeError, "canonical block changed"):
            smoke.check("test", 8192, 1)

    def test_unsupported_or_orphaned_snapshot_has_no_number_fallback(self):
        chain = ChainRPC(1)
        chain.reject_snapshot = True
        with patch.object(smoke, "rpc", chain), self.assertRaisesRegex(RuntimeError, "RPC rejected"):
            smoke.check("test", 1, 1)
        self.assertEqual([method for method, _ in chain.calls], ["eth_getBlockByNumber", "eth_getCode"])

    def test_cross_client_disagreement_fails(self):
        chains = {"client-a": ChainRPC(2), "client-b": ChainRPC(2, fork=1)}
        with patch.object(smoke, "rpc", side_effect=lambda url, method, params: chains[url](url, method, params)):
            with patch("sys.argv", ["check", "--block", "2", *chains]), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "clients disagree"):
                    smoke.main()


if __name__ == "__main__":
    unittest.main()
