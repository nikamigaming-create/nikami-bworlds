#!/usr/bin/env python3
"""Focused synthetic contracts for inventory_fnv_geck_workload.py."""

from __future__ import annotations

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("inventory_fnv_geck_workload.py")
SPEC = importlib.util.spec_from_file_location("inventory_fnv_geck_workload", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
INVENTORY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = INVENTORY
SPEC.loader.exec_module(INVENTORY)


def subrecord(name: str, payload: bytes = b"") -> bytes:
    return name.encode("ascii") + struct.pack("<H", len(payload)) + payload


def record(rtype: str, form_id: int, payload: bytes = b"", flags: int = 0) -> bytes:
    return (
        rtype.encode("ascii")
        + struct.pack("<III", len(payload), flags, form_id)
        + struct.pack("<IHH", 0, 0, 0)
        + payload
    )


def group(label: str, records: list[bytes]) -> bytes:
    payload = b"".join(records)
    return (
        b"GRUP"
        + struct.pack("<I", 24 + len(payload))
        + label.encode("ascii")
        + struct.pack("<IHHHH", 0, 0, 0, 0, 0)
        + payload
    )


def plugin(path: Path, masters: list[str], records: list[bytes]) -> None:
    header_payload = subrecord("HEDR", struct.pack("<fII", 1.34, len(records), 0x800))
    for master in masters:
        header_payload += subrecord("MAST", master.encode("ascii") + b"\0")
        header_payload += subrecord("DATA", struct.pack("<Q", 0))
    path.write_bytes(record("TES4", 0, header_payload) + group("TEST", records))


def frame(opcode: int, payload: bytes = b"") -> bytes:
    return struct.pack("<HH", opcode, len(payload)) + payload


def reference_frame(reference_index: int, opcode: int, payload: bytes = b"") -> bytes:
    return struct.pack("<HHHH", 0x1C, reference_index, opcode, len(payload)) + payload


def script_payload(
    editor_id: str,
    source: str,
    *,
    scro: int | None = None,
    bytecode: bytes | None = None,
) -> bytes:
    if bytecode is None:
        bytecode = (
            frame(0x1D)
            + frame(0x10, struct.pack("<HI", 1, 0))
            + (reference_frame(1, 0x1000) if scro is not None else frame(0x1000))
            + frame(0x11)
        )
    reference_count = int(scro is not None)
    result = (
        subrecord("EDID", editor_id.encode("ascii") + b"\0")
        + subrecord("SCHR", struct.pack("<IIIIHH", 0, reference_count, len(bytecode), 0, 0, 1))
        + subrecord("SCDA", bytecode)
        + subrecord("SCTX", source.encode("cp1252") + b"\0")
    )
    if scro is not None:
        result += subrecord("SCRO", struct.pack("<I", scro))
    return result


def condition(
    function_id: int,
    *,
    flags: int = 0,
    comparison_bits: int = 0,
    param1: int = 0,
    param2: int = 0,
    run_on: int = 0,
    reference: int = 0,
) -> bytes:
    return struct.pack(
        "<IIIIIII",
        flags,
        comparison_bits,
        function_id,
        param1,
        param2,
        run_on,
        reference,
    )


def make_layer(root: Path, *, malformed: bool = False) -> list[Path]:
    base = root / "FalloutNV.esm"
    dlc = root / "DeadMoney.esm"
    helper = root / "FNVR.esp"

    base_script = script_payload(
        "BaseScript",
        "scn BaseScript\nref owner\nbegin GameMode\nowner.SetStage BaseQuest 10\nend\n",
        scro=0x00000200,
    )
    bad_condition = bytes(21) if malformed else condition(58, run_on=2, reference=0x00000200)
    base_records = [
        record("SCPT", 0x00000100, base_script),
        record(
            "QUST",
            0x00000200,
            subrecord("EDID", b"BaseQuest\0")
            + subrecord("SCRI", struct.pack("<I", 0x00000100))
            + subrecord("CTDA", bad_condition),
        ),
        record("DIAL", 0x00000300, subrecord("EDID", b"Topic\0")),
        record(
            "INFO",
            0x00000400,
            subrecord("CTDA", condition(72, run_on=2, reference=0x00000014))
            + subrecord("SCHR", struct.pack("<IIIIHH", 0, 0, 4, 0, 0, 1))
            + subrecord("SCDA", frame(0x1D))
            + subrecord("SCTX", b"SetStage BaseQuest 10\0")
            + subrecord("NEXT")
            + subrecord("SCHR", struct.pack("<IIIIHH", 0, 1, 0, 0, 0, 0))
            + subrecord("SCTX", b"PlayerREF.PlayIdle LooseGesture\0"),
        ),
        record(
            "TERM",
            0x00000500,
            subrecord("EDID", b"Terminal\0")
            + subrecord("ITXT", b"Entry\0")
            + subrecord("SCHR", struct.pack("<IIIIHH", 0, 0, 4, 0, 0, 1))
            + subrecord("SCDA", frame(0x1D)),
        ),
        record(
            "PACK",
            0x00000600,
            subrecord("EDID", b"Package\0")
            + subrecord("POBA")
            + subrecord("SCHR", struct.pack("<IIIIHH", 0, 0, 4, 0, 0, 1))
            + subrecord("SCDA", frame(0x1D)),
        ),
        record(
            "MGEF",
            0x00000700,
            subrecord("EDID", b"Effect\0")
            + subrecord("SCRI", struct.pack("<I", 0x00000100)),
        ),
        record("GLOB", 0x00000800, subrecord("EDID", b"ComparisonGlobal\0")),
    ]
    plugin(base, [], base_records)

    # This official override must win.  Its raw index 00 still addresses the
    # base master because DeadMoney declares FalloutNV as its only master.
    dlc_script = script_payload(
        "DlcOverrideScript",
        "scn DlcOverrideScript\nbegin GameMode\nSetStage BaseQuest 20\nend\n",
        scro=0x00000200,
    )
    plugin(
        dlc,
        ["FalloutNV.esm"],
        [
            record("SCPT", 0x00000100, dlc_script),
            record(
                "QUST",
                0x01000900,
                subrecord("EDID", b"DlcQuest\0")
                + subrecord("SCRI", struct.pack("<I", 0x00000100))
                + subrecord(
                    "CTDA",
                    condition(
                        74,
                        flags=0x04,
                        comparison_bits=0x00000800,
                        run_on=0,
                    ),
                ),
            ),
        ],
    )

    # The helper would override the script again if it leaked into retail
    # semantics.  It must never appear in records, counts, or resolution.
    plugin(
        helper,
        ["FalloutNV.esm", "DeadMoney.esm"],
        [
            record(
                "SCPT",
                0x00000100,
                script_payload("HelperScript", "scn HelperScript\nend\n"),
            )
        ],
    )
    return [base, dlc, helper]


class GeckInventoryContract(unittest.TestCase):
    def test_master_aware_inventory_excludes_helper_and_emits_bites(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = make_layer(Path(temporary))
            report = INVENTORY.build_inventory(paths, require_complete_scope=False)

        self.assertTrue(report["inventoryComplete"])
        self.assertEqual(report["parseAnomalies"], [])
        self.assertEqual([item["name"] for item in report["plugins"]], ["FalloutNV.esm", "DeadMoney.esm"])
        self.assertEqual(report["excludedPluginNames"], ["FNVR.esp"])
        self.assertNotIn("HelperScript", json.dumps(report))

        script_record = next(
            item for item in report["records"] if item["formId"] == "0x00000100"
        )
        self.assertEqual(script_record["sourcePlugin"], "DeadMoney.esm")
        self.assertEqual(script_record["editorId"], "DlcOverrideScript")

        quest_attachment = next(
            item
            for item in report["scriptAttachments"]
            if item["owner"] == "form:01000900"
        )
        self.assertEqual(quest_attachment["target"]["resolved"], "0x00000100")
        self.assertEqual(quest_attachment["target"]["targetRecordType"], "SCPT")

        condition_rows = {item["functionId"]: item for item in report["conditions"]}
        self.assertEqual(condition_rows[58]["runOnName"], "reference")
        self.assertEqual(condition_rows[58]["reference"]["resolved"], "0x00000200")
        self.assertEqual(
            condition_rows[72]["reference"]["engineReserved"], "player-reference"
        )
        self.assertEqual(
            condition_rows[74]["comparisonGlobal"]["resolved"], "0x00000800"
        )

        frames = [
            frame
            for blob in report["compiledBlobs"]
            for frame in blob["frames"]
        ]
        self.assertTrue(any(frame["opcode"] == "0x1000" for frame in frames))
        ref_frame = next(frame for frame in frames if frame["referenceFunction"])
        self.assertEqual(ref_frame["callingReferenceIndex"], 1)

        bite_by_id = {item["id"]: item for item in report["workloadBites"]}
        self.assertIn("source-command:setstage", bite_by_id)
        self.assertIn("compiled-opcode:0x1000", bite_by_id)
        self.assertIn("condition-function:58", bite_by_id)
        self.assertEqual(bite_by_id["source-command:setstage"]["disposition"], "uncovered")
        self.assertEqual(
            set(report["dispositionSchema"]["allowed"]), set(INVENTORY.DISPOSITIONS)
        )
        self.assertTrue(
            any(
                item["reason"] == "source-only-unmaterialized-reference-slot"
                for item in report["unresolved"]
            )
        )

        serialized = json.dumps(report)
        self.assertNotIn(str(Path(temporary)), serialized)
        self.assertNotIn("\\", serialized)

    def test_unknown_condition_and_compiled_framing_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = make_layer(root, malformed=True)
            # Also add a malformed SCDA to a new standalone script.
            base = paths[0]
            # Rebuild only FalloutNV with the malformed condition layer plus a
            # compact dedicated fixture; parsing either anomaly must be fatal.
            bad = root / "ClassicPack.esm"
            plugin(
                bad,
                ["FalloutNV.esm"],
                [
                    record(
                        "SCPT",
                        0x01000100,
                        script_payload(
                            "BadFraming",
                            "scn BadFraming\nend\n",
                            bytecode=b"\x00\x10\x08\x00",
                        ),
                    )
                ],
            )
            report = INVENTORY.build_inventory(
                [base, paths[1], bad, paths[2]], require_complete_scope=False
            )

        self.assertFalse(report["inventoryComplete"])
        self.assertEqual(report["status"], "incomplete-parse-anomalies")
        codes = {item["code"] for item in report["parseAnomalies"]}
        self.assertIn("condition-structure", codes)
        self.assertIn("scda-framing", codes)
        self.assertGreaterEqual(report["summary"]["parseAnomalyRows"], 2)

    def test_report_is_path_independent_and_digest_is_stable(self) -> None:
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            first_report = INVENTORY.build_inventory(
                make_layer(Path(first)), require_complete_scope=False
            )
            second_report = INVENTORY.build_inventory(
                make_layer(Path(second)), require_complete_scope=False
            )

        self.assertEqual(first_report, second_report)
        digest = first_report.pop("canonicalSha256")
        self.assertEqual(digest, INVENTORY._canonical_digest(first_report))


if __name__ == "__main__":
    unittest.main()
