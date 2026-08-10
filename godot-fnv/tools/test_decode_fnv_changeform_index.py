#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import struct
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("decode_fnv_changeform_index.py")
SPEC = importlib.util.spec_from_file_location("decode_fnv_changeform_index", MODULE_PATH)
assert SPEC and SPEC.loader
decoder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = decoder
SPEC.loader.exec_module(decoder)


def refid(kind: int, value: int) -> bytes:
    return ((kind << 22) | value).to_bytes(3, "big")


def change_form(kind: int, value: int, flags: int, form_type: int, length_code: int, version: int, payload: bytes) -> bytes:
    width = (1, 2, 4)[length_code]
    return (
        refid(kind, value)
        + struct.pack("<I", flags)
        + bytes([(length_code << 6) | form_type, version])
        + len(payload).to_bytes(width, "little")
        + payload
    )


class ChangeFormParserTest(unittest.TestCase):
    def test_all_valid_length_encodings_and_exact_boundary(self) -> None:
        records = [
            change_form(1, 7, 1, 0, 0, 1, b"abc"),
            change_form(0, 2, 2, 1, 1, 2, b"m" * 300),
            change_form(2, 9, 4, 2, 2, 3, b"l" * 70000),
        ]
        prefix = b"prefix"
        data = prefix + b"".join(records) + b"suffix"
        forms, end = decoder.parse_changed_forms(data, len(prefix), 3, len(data) - len(b"suffix"))
        self.assertEqual([0, 1, 2], [f.length_code for f in forms])
        self.assertEqual([3, 300, 70000], [len(f.payload) for f in forms])
        self.assertEqual(len(data) - len(b"suffix"), end)

    def test_refid_resolution(self) -> None:
        form_ids = [0x01001234, 0x02005678]
        self.assertEqual("0x02005678", decoder.decode_refid((0 << 22) | 2, form_ids)["resolvedFormId"])
        self.assertEqual("0x00000007", decoder.decode_refid((1 << 22) | 7, form_ids)["resolvedFormId"])
        self.assertEqual("0xff000009", decoder.decode_refid((2 << 22) | 9, form_ids)["resolvedFormId"])
        self.assertIsNone(decoder.decode_refid((0 << 22) | 3, form_ids)["resolvedFormId"])

    def test_rejects_reserved_length_code(self) -> None:
        bad = refid(1, 1) + struct.pack("<I", 0) + bytes([(3 << 6), 1, 0])
        with self.assertRaises(decoder.DecodeError):
            decoder.parse_changed_forms(bad, 0, 1)

    def test_rejects_boundary_mismatch(self) -> None:
        data = change_form(1, 1, 0, 0, 0, 1, b"x")
        with self.assertRaises(decoder.DecodeError):
            decoder.parse_changed_forms(data, 0, 1, len(data) + 1)

    def test_decodes_moved_reference_prefix(self) -> None:
        payload = refid(0, 1) + struct.pack("<6f", 1.0, 2.0, 3.0, 0.1, 0.2, 0.3) + b"tail"
        data = change_form(0, 2, 1 << 1, 1, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        state = decoder.decode_initial_state(forms[0], [0x000DA726, 0x00000014])
        self.assertEqual("moved", state["kind"])
        self.assertEqual("0x000da726", state["cellOrWorldspace"]["resolvedFormId"])
        self.assertEqual([1.0, 2.0, 3.0], state["position"])
        self.assertEqual(27, state["bytes"])


if __name__ == "__main__":
    unittest.main()
