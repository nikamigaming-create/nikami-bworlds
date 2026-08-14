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
    def _decode_script_payload(self, payload: bytes, *, flags: int = 1 << 18, form_type: int = 1,
                               version: int = 27, form_ids: list[int] | None = None):
        data = change_form(1, 7, flags, form_type, 0, version, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        return decoder.decode_leading_script_state(forms[0], form_ids or [], None)

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
        payload = refid(0, 1) + struct.pack("<6f", 1.0, 2.0, 3.0, 0.1, 0.2, 0.3) + b"|tail"
        data = change_form(0, 2, 1 << 1, 1, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        state = decoder.decode_initial_state(forms[0], [0x000DA726, 0x00000014])
        self.assertEqual("moved", state["kind"])
        self.assertEqual("0x000da726", state["cellOrWorldspace"]["resolvedFormId"])
        self.assertEqual([1.0, 2.0, 3.0], state["position"])
        self.assertEqual(28, state["bytes"])

    def test_decodes_only_structurally_leading_actor_script_extra(self) -> None:
        payload = (
            b"\x03|"                 # process level
            + b"\x04|"               # one changed extra (itU6to30)
            + b"\x0d|"               # ExtraScript
            + refid(1, 0x123) + b"|"  # script RefID
            + b"\x04|"               # one local variable
            + struct.pack("<I", 2) + b"|"
            + struct.pack("<d", 7.5) + b"|"
            + b"\x00|"               # no Struct010
            + b"\x01|"               # OnLoad
            + b"opaque-tail"
        )
        data = change_form(1, 7, 1 << 18, 1, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        state = decoder.decode_leading_script_state(forms[0], [], None)
        self.assertEqual("0x00000123", state["script"]["resolvedFormId"])
        self.assertEqual(2, state["variables"][0]["index"])
        self.assertEqual(7.5, state["variables"][0]["value"])
        self.assertEqual("leading-extra-only", state["coverage"])

    def test_bit2_havok_move_consumes_terminated_count_then_raw_bytes(self) -> None:
        payload = (
            refid(0, 1) + struct.pack("<6f", 1, 2, 3, 0, 0, 0) + b"|"
            + b"\x0c|" + b"\x01\x02\x03" + b"tail"
        )
        data = change_form(0, 2, 1 << 2, 2, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        state = decoder.decode_initial_state(forms[0], [0x000DA726])
        self.assertEqual(3, state["havokBytes"])
        self.assertEqual(33, state["bytes"])

    def test_rejects_noncanonical_packed_counter(self) -> None:
        self.assertEqual((63, 2), decoder.read_counter_terminated(bytes([(63 << 2)]) + b"|", 0, "test"))
        self.assertEqual((64, 3), decoder.read_counter_terminated((64 << 2 | 1).to_bytes(2, "little") + b"|", 0, "test"))
        self.assertEqual((16384, 5), decoder.read_counter_terminated((16384 << 2 | 2).to_bytes(4, "little") + b"|", 0, "test"))
        with self.assertRaises(decoder.DecodeError):
            decoder.read_counter_terminated(b"\x05\x00|", 0, "test")
        with self.assertRaises(decoder.DecodeError):
            decoder.read_counter_terminated(b"\x06\x00\x00\x00|", 0, "test")
        with self.assertRaises(decoder.DecodeError):
            decoder.read_counter_terminated(b"\x03|", 0, "test")

    def test_created_and_cell_changed_havok_prefixes(self) -> None:
        created_payload = (
            refid(1, 3) + struct.pack("<6f", 1, 2, 3, 0.1, 0.2, 0.3)
            + b"\x05" + refid(1, 4) + b"|" + b"\x08|xy"
        )
        created_data = change_form(2, 8, 1 << 2, 1, 0, 27, created_payload)
        created_forms, _ = decoder.parse_changed_forms(created_data, 0, 1)
        created = decoder.decode_initial_state(created_forms[0], [])
        self.assertEqual("created", created["kind"])
        self.assertEqual("0x00000004", created["baseForm"]["resolvedFormId"])
        self.assertEqual(2, created["havokBytes"])
        self.assertEqual(36, created["bytes"])

        changed_payload = (
            refid(1, 3) + struct.pack("<6f", 4, 5, 6, 0.4, 0.5, 0.6)
            + refid(1, 9) + struct.pack("<hh", -2, 7) + b"|" + b"\x04|z"
        )
        changed_data = change_form(1, 8, (1 << 3) | (1 << 2), 1, 0, 27, changed_payload)
        changed_forms, _ = decoder.parse_changed_forms(changed_data, 0, 1)
        changed = decoder.decode_initial_state(changed_forms[0], [])
        self.assertEqual("cellChanged", changed["kind"])
        self.assertEqual([-2, 7], changed["newCellGrid"])
        self.assertEqual(1, changed["havokBytes"])
        self.assertEqual(38, changed["bytes"])

    def test_rejects_nonfinite_reference_transform(self) -> None:
        payload = refid(1, 3) + struct.pack("<6f", float("nan"), 2, 3, 0, 0, 0) + b"|"
        data = change_form(1, 8, 1 << 1, 1, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        with self.assertRaises(decoder.DecodeError):
            decoder.decode_initial_state(forms[0], [])

    def test_actor_prefix_flags_scale_and_player_exclusion(self) -> None:
        payload = (
            b"\x03|" + struct.pack("<I", 9) + b"|" + struct.pack("<f", 1.25) + b"|"
            + b"\x04|\x0d|" + refid(1, 0x123) + b"|\x00|\x00|\x00|"
        )
        state = self._decode_script_payload(payload, flags=(1 << 18) | 1 | (1 << 4))
        self.assertEqual("0x00000123", state["script"]["resolvedFormId"])
        player_data = change_form(1, 0x14, 1 << 18, 1, 0, 27, payload)
        player_forms, _ = decoder.parse_changed_forms(player_data, 0, 1)
        self.assertIsNone(decoder.decode_leading_script_state(player_forms[0], [], None))

    def test_script_reference_union_struct_and_version_boundary(self) -> None:
        payload = (
            b"\x03|\x04|\x0d|" + refid(1, 0x123) + b"|\x04|"
            + struct.pack("<I", 0x80000005) + b"|" + refid(0, 1) + b"|"
            + b"\x01|" + b"12345678|" + b"\x01|"
        )
        state = self._decode_script_payload(payload, form_ids=[0x0200ABCD])
        self.assertTrue(state["hasStruct010"])
        self.assertEqual("reference", state["variables"][0]["kind"])
        self.assertEqual("0x0200abcd", state["variables"][0]["value"]["resolvedFormId"])
        self.assertEqual(1, state["onLoad"])

        version20 = payload[:-2]
        state20 = self._decode_script_payload(version20, version=20, form_ids=[0x0200ABCD])
        self.assertIsNone(state20["onLoad"])

    def test_rejects_zero_duplicate_and_nonfinite_script_locals(self) -> None:
        prefix = b"\x03|\x04|\x0d|" + refid(1, 0x123) + b"|"
        for variables in (
            b"\x04|" + struct.pack("<I", 0) + b"|" + struct.pack("<d", 1.0) + b"|",
            b"\x08|" + struct.pack("<I", 2) + b"|" + struct.pack("<d", 1.0) + b"|"
            + struct.pack("<I", 2) + b"|" + struct.pack("<d", 2.0) + b"|",
            b"\x04|" + struct.pack("<I", 2) + b"|" + struct.pack("<d", float("inf")) + b"|",
        ):
            with self.subTest(variables=variables):
                with self.assertRaises(decoder.DecodeError):
                    self._decode_script_payload(prefix + variables + b"\x00|\x00|")

    def test_nonleading_script_is_promoted_only_after_full_list_walk(self) -> None:
        payload = (
            b"\x03|\x08|\x18|" + refid(1, 9) + b"|"
            + struct.pack("<3f", 1, 2, 3) + b"|" + struct.pack("<I", 0) + b"|"
            + b"\x0d|" + refid(1, 0x123) + b"|\x00|\x00|\x00|"
        )
        data = change_form(1, 7, 1 << 11, 1, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        self.assertIsNone(decoder.decode_leading_script_state(forms[0], [], None))
        summary = decoder.decode_changed_extra_summary(forms[0], [], None)
        self.assertTrue(summary["fullyDecoded"])
        self.assertEqual([0x18, 0x0D], summary["extraTypes"])
        self.assertEqual("0x00000123", summary["scriptState"]["script"]["resolvedFormId"])

    def test_decodes_complete_quest_change_form(self) -> None:
        flags = 1 | (1 << 1) | (1 << 2) | (1 << 29) | (1 << 30) | (1 << 31)
        payload = (
            struct.pack("<I", 0x1234) + b"|"       # form flags
            + b"\x23|"                              # running, completed, shown
            + struct.pack("<f", 1.5) + b"|"
            + b"\x04|"                              # one stage
            + b"\x0a|\x01|"                        # stage 10, done
            + b"\x04|\x00|\x01|"                  # one log, id 0, has data
            + struct.pack("<H", 7) + struct.pack("<H", 8) + b"|"
            + b"\x04|"                              # one script variable
            + struct.pack("<I", 3) + b"|" + struct.pack("<d", 9.25) + b"|"
            + b"\x00|\x01|"                        # no struct, OnLoad
            + b"\x04|"                              # one objective
            + struct.pack("<i", 10) + b"|" + struct.pack("<I", 3) + b"|"
        )
        data = change_form(1, 0x777, flags, 9, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        state = decoder.decode_quest_state(forms[0], [])
        self.assertEqual(0x23, state["flags"])
        self.assertEqual(1.5, state["scriptDelay"])
        self.assertEqual({"id": 10, "done": True, "status": 1,
                          "logs": [{"id": 0, "hasData": True, "data": [7, 8]}]}, state["stages"][0])
        self.assertEqual(9.25, state["scriptState"]["variables"][0]["value"])
        self.assertEqual({"id": 10, "flags": 3}, state["objectives"][0])
        self.assertEqual(len(payload), state["bytes"])

    def test_quest_decoder_rejects_trailing_or_duplicate_state(self) -> None:
        trailing = change_form(1, 1, 1 << 1, 9, 0, 27, b"\x01|x")
        forms, _ = decoder.parse_changed_forms(trailing, 0, 1)
        with self.assertRaises(decoder.DecodeError):
            decoder.decode_quest_state(forms[0], [])
        duplicate_stages = change_form(
            1, 1, 1 << 31, 9, 0, 27,
            b"\x08|\x0a|\x01|\x00|\x0a|\x01|\x00|",
        )
        forms, _ = decoder.parse_changed_forms(duplicate_stages, 0, 1)
        with self.assertRaises(decoder.DecodeError):
            decoder.decode_quest_state(forms[0], [])

    def test_fully_walks_supported_non_script_changed_extra(self) -> None:
        payload = (
            b"\x03|\x04|\x18|" + refid(1, 9) + b"|"
            + struct.pack("<3f", 1, 2, 3) + b"|" + struct.pack("<I", 0) + b"|"
        )
        data = change_form(1, 7, 1 << 11, 1, 0, 27, payload)
        forms, _ = decoder.parse_changed_forms(data, 0, 1)
        summary = decoder.decode_changed_extra_summary(forms[0], [], None)
        self.assertTrue(summary["fullyDecoded"])
        self.assertEqual([0x18], summary["extraTypes"])
        self.assertIsNone(summary["scriptState"])


if __name__ == "__main__":
    unittest.main()
