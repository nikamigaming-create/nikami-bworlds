#!/usr/bin/env python3
"""Focused contracts for generate_fnv_bite_ledger.py."""

from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("generate_fnv_bite_ledger.py")
ROW_SCHEMA = SCRIPT.parents[1] / "catalog" / "fnv-bite-ledger.schema.json"
SPEC = importlib.util.spec_from_file_location("generate_fnv_bite_ledger", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
LEDGER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = LEDGER
SPEC.loader.exec_module(LEDGER)


def workload_bite(kind: str, key: str) -> dict:
    return {
        "affectedRecords": 1,
        "authoredOccurrences": 1,
        "disposition": "uncovered",
        "evidence": [],
        "id": f"{kind}:{key}",
        "implementationArtifacts": [],
        "key": key,
        "kind": kind,
        "notes": "",
    }


def base_report() -> dict:
    bites = sorted(
        [
            workload_bite("compiled-event", "0x0001"),
            workload_bite("compiled-opcode", "0x1000"),
            workload_bite("condition-function", "42"),
            workload_bite("condition-run-on", "subject"),
            workload_bite("script-attachment-owner", "INFO"),
            workload_bite("script-context", "standalone"),
            workload_bite("source-command", "disable"),
        ],
        key=lambda item: (item["kind"], item["key"]),
    )
    report = {
        "compiledBlobs": [
            {
                "id": "form:00000001:script:0:scda:0",
                "owner": "form:00000001",
                "frames": [{"opcode": "0x1000", "eventOpcode": "0x0001"}],
            }
        ],
        "conditions": [
            {
                "id": "form:00000002:condition:0",
                "owner": "form:00000002",
                "functionId": 42,
                "runOnName": "subject",
            }
        ],
        "dispositionSchema": {
            "allowed": list(LEDGER.ALLOWED_DISPOSITIONS),
            "default": "uncovered",
            "meaning": "synthetic",
        },
        "excludedPluginNames": ["FNVR.esp"],
        "inventoryComplete": True,
        "parseAnomalies": [],
        "plugins": LEDGER._expected_plugin_rows(),
        "recordFamilies": {},
        "records": [
            {
                "id": "form:00000001",
                "recordType": "SCPT",
                "sourcePlugin": "FalloutNV.esm",
            },
            {
                "id": "form:00000002",
                "recordType": "INFO",
                "sourcePlugin": "DeadMoney.esm",
            },
        ],
        "schema": LEDGER.REPORT_SCHEMA,
        "scopeId": LEDGER.SCOPE_ID,
        "scriptAttachments": [
            {
                "id": "form:00000002:scri:0",
                "owner": "form:00000002",
                "ownerRecordType": "INFO",
                "sourcePlugin": "DeadMoney.esm",
            }
        ],
        "scriptSegments": [
            {
                "id": "form:00000001:script:0",
                "owner": "form:00000001",
                "context": "standalone",
            }
        ],
        "semantics": {},
        "sourceBlobs": [
            {
                "id": "form:00000001:script:0:sctx:0",
                "owner": "form:00000001",
                "commandCandidates": [{"token": "disable", "role": "statement"}],
            }
        ],
        "sourceTokens": [],
        "status": "inventory-complete",
        "summary": {
            "disposedWorkloadBites": 0,
            "parseAnomalyRows": 0,
            "unresolvedRows": 0,
            "workloadBites": len(bites),
        },
        "unresolved": [],
        "workloadBites": bites,
    }
    report["canonicalSha256"] = LEDGER._canonical_digest(report)
    return report


def encode_report(report: dict) -> tuple[bytes, object]:
    canonical = dict(report)
    canonical.pop("canonicalSha256", None)
    report["canonicalSha256"] = LEDGER._canonical_digest(canonical)
    raw = LEDGER._canonical_bytes(report) + b"\n"
    pins = LEDGER.ReportPins(len(raw), LEDGER._sha256(raw), report["canonicalSha256"])
    return raw, pins


class BiteLedgerContract(unittest.TestCase):
    def test_all_equivalence_classes_are_canonical_uncovered_rows(self) -> None:
        report = base_report()
        raw, pins = encode_report(report)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            left = root / "left"
            right = root / "right"
            left.mkdir()
            right.mkdir()
            for directory in (left, right):
                (directory / "report.json").write_bytes(raw)
                (directory / "row-schema.json").write_bytes(ROW_SCHEMA.read_bytes())
                (directory / "generator.py").write_bytes(SCRIPT.read_bytes())

            left_ledger, left_bytes = LEDGER.generate(
                left / "report.json",
                left / "row-schema.json",
                report_pins=pins,
                generator_path=left / "generator.py",
            )
            right_ledger, right_bytes = LEDGER.generate(
                right / "report.json",
                right / "row-schema.json",
                report_pins=pins,
                generator_path=right / "generator.py",
            )

            self.assertEqual(left_bytes, right_bytes)
            self.assertNotIn(str(root).encode("utf-8"), left_bytes)
            self.assertEqual(left_ledger["summary"]["inputRows"], 7)
            self.assertEqual(left_ledger["summary"]["outputRows"], 7)
            self.assertEqual(left_ledger["summary"]["droppedRows"], 0)
            self.assertEqual(left_ledger["summary"]["parityCreditRows"], 0)
            self.assertEqual(left_ledger["canonicalSha256"], right_ledger["canonicalSha256"])
            self.assertTrue(
                all(
                    row["implementation"]["disposition"] == "uncovered"
                    and row["status"] == "cataloged"
                    and row["evidence"]["manifestSha256"] is None
                    for row in left_ledger["rows"]
                )
            )
            opcode = next(
                row
                for row in left_ledger["rows"]
                if row["source"]["identity"] == "compiled-opcode:0x1000"
            )
            self.assertIn("authored-occurrences=1", opcode["variants"])
            self.assertIn("affected-records=1", opcode["variants"])
            self.assertIn("record-family=SCPT", opcode["variants"])
            self.assertIn("source-plugin=FalloutNV.esm", opcode["variants"])
            source_command = next(
                row
                for row in left_ledger["rows"]
                if row["source"]["identity"] == "source-command:disable"
            )
            self.assertIn("classification=lexical-candidate", source_command["variants"])

    def test_report_raw_hash_is_pinned(self) -> None:
        report = base_report()
        raw, pins = encode_report(report)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_bytes(raw + b" ")
            with self.assertRaisesRegex(LEDGER.LedgerError, "byte size mismatch"):
                LEDGER.load_pinned_report(path, pins)

    def test_unknown_bite_kind_fails_closed(self) -> None:
        report = base_report()
        report["workloadBites"].append(workload_bite("future-unknown", "x"))
        report["workloadBites"].sort(key=lambda item: (item["kind"], item["key"]))
        report["summary"]["workloadBites"] += 1
        raw, pins = encode_report(report)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_bytes(raw)
            loaded = LEDGER.load_pinned_report(path, pins)
            observations = LEDGER.reconstruct_observations(loaded)
            with self.assertRaisesRegex(LEDGER.LedgerError, "Unknown workload bite kind"):
                LEDGER._validated_input_bites(loaded, observations)

    def test_duplicate_bite_id_fails_closed(self) -> None:
        report = base_report()
        report["workloadBites"].insert(1, copy.deepcopy(report["workloadBites"][0]))
        report["summary"]["workloadBites"] += 1
        raw, pins = encode_report(report)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_bytes(raw)
            loaded = LEDGER.load_pinned_report(path, pins)
            observations = LEDGER.reconstruct_observations(loaded)
            with self.assertRaisesRegex(LEDGER.LedgerError, "Duplicate workload bite id"):
                LEDGER._validated_input_bites(loaded, observations)

    def test_count_mismatch_fails_closed(self) -> None:
        report = base_report()
        report["workloadBites"][0]["authoredOccurrences"] = 2
        raw, pins = encode_report(report)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_bytes(raw)
            loaded = LEDGER.load_pinned_report(path, pins)
            observations = LEDGER.reconstruct_observations(loaded)
            with self.assertRaisesRegex(LEDGER.LedgerError, "Authored occurrence mismatch"):
                LEDGER._validated_input_bites(loaded, observations)

    def test_row_schema_rejects_unknown_fields_and_parity_dispositions(self) -> None:
        schema = LEDGER.load_pinned_row_schema(ROW_SCHEMA)
        report = base_report()
        observations = LEDGER.reconstruct_observations(report)
        bite = report["workloadBites"][0]
        row = LEDGER._ledger_row(
            bite,
            observations[(bite["kind"], bite["key"])],
            report["canonicalSha256"],
        )
        unknown = copy.deepcopy(row)
        unknown["unknown"] = True
        with self.assertRaisesRegex(LEDGER.LedgerError, "additional properties"):
            LEDGER.validate_schema_instance(unknown, schema)
        credited = copy.deepcopy(row)
        credited["implementation"]["disposition"] = "proved-by-wishful-thinking"
        with self.assertRaisesRegex(LEDGER.LedgerError, "outside enum"):
            LEDGER.validate_schema_instance(credited, schema)


if __name__ == "__main__":
    unittest.main()
