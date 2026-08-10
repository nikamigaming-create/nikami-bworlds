#!/usr/bin/env python3
"""Focused regression coverage for Fallout PACK semantic decoding."""

from __future__ import annotations

import importlib.util
import struct
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "export_esm4_catalog.py"
SPEC = importlib.util.spec_from_file_location("export_esm4_catalog", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PackSemanticTests(unittest.TestCase):
    def make_catalog(self):
        catalog = MODULE.ESM4Catalog.__new__(MODULE.ESM4Catalog)
        catalog.mod_index = 0
        catalog.form_resolver = lambda raw: raw | 0x01000000 if raw else None
        catalog.localized = False
        return catalog

    @staticmethod
    def payload(*rows):
        return b"".join(name.encode("ascii") + struct.pack("<H", len(raw)) + raw for name, raw in rows)

    def test_fonv_package_schedule_location_target_and_idle(self):
        payload = self.payload(
            ("EDID", b"TestSandbox\0"),
            ("PKDT", struct.pack("<IBBHHH", 0x1234, 3, 0, 0x55, 0x66, 0)),
            ("PSDT", struct.pack("<BBBBI", 0xFF, 2, 0, 18, 6)),
            ("PLDT", struct.pack("<iIi", 0, 0x123, 512)),
            ("PTDT", struct.pack("<iIif", 2, 42, 128, 0.25)),
            ("IDLF", b"\x03"),
            ("IDLC", struct.pack("<I", 2)),
            ("IDLT", struct.pack("<f", 1.5)),
            ("IDLA", struct.pack("<II", 0x456, 0x789)),
            ("CTDA", bytes(range(20))),
        )
        fields = self.make_catalog().parse_payload("PACK", payload, 0)
        self.assertEqual(fields["packageData"]["type"], 3)
        self.assertEqual(fields["packageData"]["procedureFlags"], 0x55)
        self.assertEqual(fields["packageSchedule"]["time"], 18)
        self.assertEqual(fields["packageSchedule"]["duration"], 6)
        self.assertEqual(fields["packageLocation"]["location"], 0x01000123)
        self.assertTrue(fields["packageLocation"]["locationIsForm"])
        self.assertEqual(fields["packageTarget"]["target"], 42)
        self.assertFalse(fields["packageTarget"]["targetIsForm"])
        self.assertEqual(fields["packageIdleAnimations"], [0x01000456, 0x01000789])
        self.assertEqual(fields["conditionData"][0]["bytes"], 20)

    def test_condition_layout_operator_global_and_form_parameter(self):
        # OR-with-next, use-global, greater-or-equal, GetIsID(FormID), run on reference.
        flags = 0x01 | 0x04 | 0x60
        payload = struct.pack("<IIIII", flags, 0x00000123, 72, 0x00000456, 0) + struct.pack("<II", 2, 0x00000789)
        fields = self.make_catalog().parse_payload("PACK", self.payload(("CTDA", payload)), 0)
        condition = fields["conditionData"][0]
        self.assertTrue(condition["supportedLayout"])
        self.assertTrue(condition["orWithNext"])
        self.assertTrue(condition["comparisonUsesGlobal"])
        self.assertEqual(condition["operator"], "greater_or_equal")
        self.assertEqual(condition["functionId"], 72)
        self.assertTrue(condition["param1IsForm"])
        self.assertEqual(condition["runOn"], 2)


if __name__ == "__main__":
    unittest.main()
