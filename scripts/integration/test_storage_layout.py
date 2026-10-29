"""Regression tests for the normalization behind the pinned storage layouts."""

import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "storage_layout_check", Path(__file__).resolve().parents[1] / "check-storage-layout.py"
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

IDENTIFIER = "src/Example.sol:Example"


def layout(member_slot=0, struct_ast_id=953, gap_length=80):
    """A `forge inspect storageLayout` output shaped like WrappedDoge's."""
    struct_key = f"t_struct(Counter){struct_ast_id}_storage"
    return {
        "storage": [
            {
                "astId": 11,
                "contract": IDENTIFIER,
                "label": "__gap",
                "offset": 0,
                "slot": "0",
                "type": f"t_array(t_uint256){gap_length}_storage",
            },
            {
                "astId": 22,
                "contract": IDENTIFIER,
                "label": "_nonces",
                "offset": 0,
                "slot": str(gap_length),
                "type": f"t_mapping(t_address,{struct_key})",
            },
        ],
        "types": {
            "t_address": {"encoding": "inplace", "label": "address", "numberOfBytes": "20"},
            f"t_array(t_uint256){gap_length}_storage": {
                "encoding": "inplace",
                "label": f"uint256[{gap_length}]",
                "numberOfBytes": str(32 * gap_length),
                "base": "t_uint256",
            },
            f"t_mapping(t_address,{struct_key})": {
                "encoding": "mapping",
                "label": "mapping(address => struct Counters.Counter)",
                "numberOfBytes": "32",
                "key": "t_address",
                "value": struct_key,
            },
            struct_key: {
                "encoding": "inplace",
                "label": "struct Counters.Counter",
                "numberOfBytes": "32",
                "members": [
                    {
                        "astId": 33,
                        "contract": IDENTIFIER,
                        "label": "_value",
                        "offset": 0,
                        "slot": str(member_slot),
                        "type": "t_uint256",
                    }
                ],
            },
            "t_uint256": {"encoding": "inplace", "label": "uint256", "numberOfBytes": "32"},
        },
    }


class Normalization(unittest.TestCase):
    def test_records_variables_and_struct_members(self):
        snapshot = json.loads(check.normalize(IDENTIFIER, layout()))
        self.assertEqual(
            snapshot["storage"],
            [
                {"label": "__gap", "slot": 0, "offset": 0, "type": "uint256[80]"},
                {
                    "label": "_nonces",
                    "slot": 80,
                    "offset": 0,
                    "type": "mapping(address => struct Counters.Counter)",
                },
            ],
        )
        self.assertEqual(
            snapshot["structs"],
            {"struct Counters.Counter": [{"label": "_value", "slot": 0, "offset": 0, "type": "uint256"}]},
        )

    def test_ast_ids_do_not_change_the_snapshot(self):
        # Recompiling an unrelated file renumbers AST nodes; the pins must not move.
        self.assertEqual(
            check.normalize(IDENTIFIER, layout(struct_ast_id=953)),
            check.normalize(IDENTIFIER, layout(struct_ast_id=12_481)),
        )

    def test_a_struct_member_that_moves_changes_the_snapshot(self):
        # The struct is a mapping value, so no other variable shifts, but the contract
        # would read its permit nonces from a different slot than the state it holds.
        self.assertNotEqual(
            check.normalize(IDENTIFIER, layout(member_slot=0)),
            check.normalize(IDENTIFIER, layout(member_slot=1)),
        )

    def test_a_resized_gap_changes_the_snapshot(self):
        # The digits in `t_array(t_uint256)80_storage` are a length, not an AST id.
        self.assertNotEqual(
            check.normalize(IDENTIFIER, layout(gap_length=80)),
            check.normalize(IDENTIFIER, layout(gap_length=79)),
        )

    def test_unexpected_output_is_rejected(self):
        # A future `forge inspect` that reshapes its JSON must fail loudly, not pass.
        with self.assertRaises(RuntimeError):
            check.normalize(IDENTIFIER, {"storageLayout": layout()})

    def test_two_types_cannot_be_merged_by_stripping_ids(self):
        # Two same-named structs from different files would otherwise collapse into one.
        clashing = layout()
        other = dict(clashing["types"]["t_struct(Counter)953_storage"])
        other["numberOfBytes"] = "64"
        clashing["types"]["t_struct(Counter)777_storage"] = other
        with self.assertRaises(RuntimeError):
            check.normalize(IDENTIFIER, clashing)


if __name__ == "__main__":
    unittest.main()
