#!/usr/bin/env python3

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audit_fnv_quest_bytecode import parse_quest


def subrecord(name, payload):
    return name.encode("ascii") + struct.pack("<H", len(payload)) + payload


class ParseQuestTests(unittest.TestCase):
    def test_source_without_scda_does_not_overwrite_prior_stage(self):
        stage_10_source = b"SetAlly SunnySmilesFaction PlayerFaction\0"
        stage_20_source = b"set timer to 5\0"
        payload = b"".join(
            (
                subrecord("EDID", b"VCG02\0"),
                subrecord("INDX", struct.pack("<h", 10)),
                subrecord("QSDT", b"\0"),
                subrecord("SCDA", struct.pack("<HH", 0x1079, 0)),
                subrecord("SCTX", stage_10_source),
                subrecord("INDX", struct.pack("<h", 20)),
                subrecord("QSDT", b"\0"),
                subrecord("SCTX", stage_20_source),
            )
        )

        quest = parse_quest(0x0010A214, payload)

        self.assertEqual(quest["editorId"], "VCG02")
        self.assertEqual(len(quest["scripts"]), 1)
        self.assertEqual(quest["scripts"][0]["stage"], 10)
        self.assertEqual(quest["scripts"][0]["source"], stage_10_source[:-1].decode())

    def test_new_entry_without_scda_does_not_overwrite_prior_entry(self):
        first_source = b"SetStage CGTutorial 54\0"
        payload = b"".join(
            (
                subrecord("INDX", struct.pack("<h", 10)),
                subrecord("QSDT", b"\0"),
                subrecord("SCDA", struct.pack("<HH", 0x1017, 0)),
                subrecord("SCTX", first_source),
                subrecord("QSDT", b"\0"),
                subrecord("SCTX", b"set timer to 5\0"),
            )
        )

        quest = parse_quest(0x0010A214, payload)

        self.assertEqual(len(quest["scripts"]), 1)
        self.assertEqual(quest["scripts"][0]["entry"], 0)
        self.assertEqual(quest["scripts"][0]["source"], first_source[:-1].decode())


if __name__ == "__main__":
    unittest.main()
