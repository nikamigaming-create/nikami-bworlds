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

    def test_get_script_variable_resolves_reference_parameter(self):
        payload = struct.pack("<IIIII", 0, struct.unpack("<I", struct.pack("<f", 1.0))[0], 53, 0x456, 7)
        fields = self.make_catalog().parse_payload("PACK", self.payload(("CTDA", payload)), 0)
        condition = fields["conditionData"][0]
        self.assertEqual(condition["functionId"], 53)
        self.assertTrue(condition["param1IsForm"])
        self.assertEqual(condition["param1"], 0x01000456)
        self.assertEqual(condition["param2Raw"], 7)

    def test_quest_parameter_is_resolved_as_form_id(self):
        payload = struct.pack("<IIIII", 0, 0, 79, 0x456, 7)
        fields = self.make_catalog().parse_payload("PACK", self.payload(("CTDA", payload)), 0)
        condition = fields["conditionData"][0]
        self.assertEqual(condition["functionId"], 79)
        self.assertTrue(condition["param1IsForm"])
        self.assertEqual(condition["param1"], 0x01000456)

    def test_numeric_parameter_is_not_misclassified_as_form_id(self):
        payload = struct.pack("<IIIII", 0, 0, 286, 0x456, 7)
        fields = self.make_catalog().parse_payload("PACK", self.payload(("CTDA", payload)), 0)
        condition = fields["conditionData"][0]
        self.assertEqual(condition["functionId"], 286)
        self.assertFalse(condition["param1IsForm"])
        self.assertEqual(condition["param1"], 0x456)

    def test_fonv_sound_and_consumer_references(self):
        sound = self.make_catalog().parse_payload("SOUN", self.payload(
            ("EDID", b"TestRandom\0"),
            ("FNAM", b"fx\\test\\family\\\0"),
            ("RNAM", b"\x08"),
            ("SNDD", bytes.fromhex("0102fe000510000006000708") + bytes(24)),
        ), 0)
        self.assertEqual(sound["soundFile"], "fx\\test\\family\\")
        self.assertEqual(sound["soundRnamByte"], 8)
        self.assertEqual(sound["soundData"]["frequencyAdjustment"], -2)
        self.assertEqual(sound["soundData"]["flags"], 0x1005)

        door = self.make_catalog().parse_payload("DOOR", self.payload(
            ("SNAM", struct.pack("<I", 0x100)),
            ("ANAM", struct.pack("<I", 0x101)),
            ("BNAM", struct.pack("<I", 0x102)),
        ), 0)
        self.assertEqual(door["openSound"], 0x01000100)
        self.assertEqual(door["closeSound"], 0x01000101)
        self.assertEqual(door["loopSound"], 0x01000102)

        weapon = self.make_catalog().parse_payload("WEAP", self.payload(
            ("SNAM", struct.pack("<I", 0x200)),
            ("NAM8", struct.pack("<I", 0x201)),
        ), 0)
        self.assertEqual([row["slot"] for row in weapon["weaponSounds"]], ["SNAM", "NAM8"])

    def test_fonv_patrol_link_semantics(self):
        fields = self.make_catalog().parse_payload("REFR", self.payload(
            ("XLKR", struct.pack("<I", 0x300)),
            ("XPRD", struct.pack("<f", 2.5)),
            ("XPPA", b""),
        ), 0)
        self.assertEqual(fields["linkedReference"], 0x01000300)
        self.assertAlmostEqual(fields["patrolIdleSeconds"], 2.5)
        self.assertTrue(fields["patrolIdleScriptMarker"])

    def test_fonv_script_definition_and_actor_attachment(self):
        catalog = self.make_catalog()
        script = catalog.parse_payload("SCPT", self.payload(
            ("EDID", b"TestActorScript\0"),
            ("SCHR", struct.pack("<IIIIHH", 0, 1, 4, 2, 0, 1)),
            ("SLSD", struct.pack("<IIIIII", 1, 2, 3, 4, 5, 6)),
            ("SCVR", b"State\0"),
            ("SLSD", struct.pack("<IIIIII", 2, 0, 0, 0, 1, 0)),
            ("SCVR", b"Timer\0"),
            ("SCRV", struct.pack("<I", 2)),
            ("SCRO", struct.pack("<I", 0x123)),
            ("SCDA", b"\x01\x02\x03\x04"),
            ("SCTX", b"scn TestActorScript\nbegin gamemode\nend\0"),
        ), 0)
        self.assertEqual(script["scriptHeader"]["variableCount"], 2)
        self.assertEqual(script["scriptLocals"][0]["index"], 1)
        self.assertEqual(script["scriptLocals"][0]["name"], "State")
        self.assertEqual(script["scriptLocals"][1]["name"], "Timer")
        self.assertEqual(script["scriptLocalReferenceIndices"], [2])
        self.assertEqual(script["scriptReferences"], [0x01000123])
        self.assertEqual(script["scriptBytecode"]["bytes"], 4)
        self.assertIn("begin gamemode", script["scriptSource"])

        actor = catalog.parse_payload("NPC_", self.payload(("SCRI", struct.pack("<I", 0x456))), 0)
        self.assertEqual(actor["script"], 0x01000456)

        terminal = catalog.parse_payload("TERM", self.payload(("SCRI", struct.pack("<I", 0x789))), 0)
        self.assertEqual(terminal["script"], 0x01000789)

    def test_fonv_quest_runtime_defaults_stages_and_objectives(self):
        quest = self.make_catalog().parse_payload("QUST", self.payload(
            ("EDID", b"TestQuest\0"),
            ("DATA", struct.pack("<BBHf", 0x09, 50, 0, 5.0)),
            ("SCRI", struct.pack("<I", 0x789)),
            ("INDX", struct.pack("<h", 10)),
            ("QSDT", b"\x01"),
            ("QSDT", b"\x02"),
            ("QOBJ", struct.pack("<i", 20)),
            ("QSTA", struct.pack("<IB3s", 0x456, 1, b"\0\0\0")),
        ), 0)
        self.assertEqual({"flags": 0x09, "priority": 50, "delay": 5.0}, quest["questData"])
        self.assertEqual(0x01000789, quest["script"])
        self.assertEqual(10, quest["questStages"][0]["index"])
        self.assertEqual([1, 2], [row["flags"] for row in quest["questStages"][0]["entries"]])
        self.assertEqual(20, quest["questObjectives"][0]["index"])
        self.assertEqual(0x01000456, quest["questObjectives"][0]["targets"][0]["target"])


if __name__ == "__main__":
    unittest.main()
