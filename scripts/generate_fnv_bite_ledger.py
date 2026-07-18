#!/usr/bin/env python3
"""Generate the canonical FNV workload-equivalence bite ledger.

The input is the pinned, official-layer report produced by
``inventory_fnv_geck_workload.py``.  Every input ``workloadBites`` row must be
reconstructed exactly from the detailed artifacts before it can become one
schema-valid ledger row.  Nothing in this generator awards parity: every row
is cataloged with the sole disposition ``uncovered`` and no evidence manifest.

Local paths are read but never serialized.  The compact output is therefore
identical when byte-identical inputs are copied to another directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


REPORT_SCHEMA = "nikami-fnv-geck-workload/v1"
LEDGER_SCHEMA = "nikami-fnv-bite-ledger/v1"
ROW_SCHEMA_ID = "nikami-fnv-bite-ledger-row/v1"
SCOPE_ID = "fnv-ultimate-edition-en-official-v1"

FROZEN_REPORT_BYTES = 233_292_659
FROZEN_REPORT_SHA256 = "d568d2ba6ab75aa15c0e859101175d8dcd0ad866895ef8a2ee3e9559ccf29157"
FROZEN_REPORT_CANONICAL_SHA256 = (
    "c61ebb5300bcfba77d79f78a97634e5852f7dbf8ef20fbcdc98951d589bb6ab4"
)
FROZEN_ROW_SCHEMA_SHA256 = (
    "a27f5f5bf58588cf2ace328dd3905d73046f353bc4087795ccc2758539fa1552"
)

ALLOWED_DISPOSITIONS = (
    "existing-cpp-analog",
    "new-cpp-runtime",
    "lua-retail-script",
    "data-only",
    "retail-unreachable",
    "uncovered",
)

EXPECTED_REPORT_KEYS = frozenset(
    {
        "canonicalSha256",
        "compiledBlobs",
        "conditions",
        "dispositionSchema",
        "excludedPluginNames",
        "inventoryComplete",
        "parseAnomalies",
        "plugins",
        "recordFamilies",
        "records",
        "schema",
        "scopeId",
        "scriptAttachments",
        "scriptSegments",
        "semantics",
        "sourceBlobs",
        "sourceTokens",
        "status",
        "summary",
        "unresolved",
        "workloadBites",
    }
)

EXPECTED_WORKLOAD_BITE_KEYS = frozenset(
    {
        "affectedRecords",
        "authoredOccurrences",
        "disposition",
        "evidence",
        "id",
        "implementationArtifacts",
        "key",
        "kind",
        "notes",
    }
)

EXPECTED_PLUGINS = (
    (0, "FalloutNV.esm", 245_650_747, "50991d36804b7d1e70df1afd7471b72f0e29d1b456ee2516a9717c002564e7c1"),
    (1, "DeadMoney.esm", 6_274_851, "31ede9c21ae6960ec868bf60879c602bf7a13879b2f47e7cfd1ac30b4d4de329"),
    (2, "HonestHearts.esm", 17_308_500, "4341d1a35eaac7d9e7097ebac8f31a13264ca6dcb33443408bd97e5ddd5d8368"),
    (3, "OldWorldBlues.esm", 16_202_800, "fd6cc6e582582ec035277150e106d12b6d78c7c60cbb506545e06d1fa7212295"),
    (4, "LonesomeRoad.esm", 25_676_818, "41bf457c1ed313834407840d2b60447f74264e33b372590454ead8ac663b0516"),
    (5, "GunRunnersArsenal.esm", 252_445, "aee27930699494f0626d24a3a8ae947fe447e33edc0ed46762e54faab4c05a1e"),
    (6, "CaravanPack.esm", 3_007, "0473cff52d375a77d6585f203a914445fa5a9e6ba726818aa7d8d48cb177ec82"),
    (7, "ClassicPack.esm", 6_523, "3b31928dfdac46028f2e12f25b0dbdd0e809d4d74ac04fb7783e0063e912760b"),
    (8, "MercenaryPack.esm", 3_064, "73e76bcadbf326818af7b58c315773a2d86fe3a8186a778e84a68916cb830c59"),
    (9, "TribalPack.esm", 2_323, "342f42ce9835f57ee19be09f12ad0ba2c6182e86740338202fcea9011d62f328"),
)

# This is an exhaustive mapping of the inventory's equivalence-class kinds.
# An inventory update that introduces another kind is intentionally fatal.
KIND_POLICY = {
    "compiled-event": {
        "biteKind": "event",
        "dependencies": ("geck-bytecode-decoder", "geck-event-scheduler"),
    },
    "compiled-opcode": {
        "biteKind": "script-opcode",
        "dependencies": ("geck-bytecode-decoder", "geck-vm-command-dispatch"),
    },
    "condition-function": {
        "biteKind": "condition-function",
        "dependencies": ("geck-condition-dispatch", "geck-formid-resolution"),
    },
    "condition-run-on": {
        "biteKind": "condition-function",
        "dependencies": ("geck-condition-dispatch", "geck-run-on-context"),
    },
    "script-attachment-owner": {
        "biteKind": "mechanic-variant",
        "dependencies": ("geck-formid-resolution", "geck-script-attachment-binding"),
    },
    "script-context": {
        "biteKind": "event",
        "dependencies": ("geck-script-lifecycle", "geck-vm-scheduler"),
    },
    "source-command": {
        "biteKind": "script-command",
        "dependencies": ("geck-command-symbol-resolution", "geck-vm-command-dispatch"),
    },
}


class LedgerError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ReportPins:
    bytes: int
    raw_sha256: str
    canonical_sha256: str


FROZEN_REPORT_PINS = ReportPins(
    FROZEN_REPORT_BYTES,
    FROZEN_REPORT_SHA256,
    FROZEN_REPORT_CANONICAL_SHA256,
)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_bytes(value: Mapping) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _canonical_digest(value: Mapping) -> str:
    return _sha256(_canonical_bytes(value))


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LedgerError(message)


def _expected_plugin_rows() -> list[dict]:
    return [
        {
            "order": order,
            "name": name,
            "bytes": size,
            "sha256": sha256,
            "masters": [] if order == 0 else ["FalloutNV.esm"],
        }
        for order, name, size, sha256 in EXPECTED_PLUGINS
    ]


def load_pinned_report(path: Path, pins: ReportPins = FROZEN_REPORT_PINS) -> dict:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise LedgerError(f"Cannot read workload report: {error}") from error
    actual_sha = _sha256(raw)
    _require(len(raw) == pins.bytes, f"Workload report byte size mismatch: {len(raw)} != {pins.bytes}")
    _require(actual_sha == pins.raw_sha256, f"Workload report SHA-256 mismatch: {actual_sha}")
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as error:
        raise LedgerError(f"Workload report is not valid JSON: {error}") from error
    _require(isinstance(report, dict), "Workload report root must be an object")
    _require(
        frozenset(report) == EXPECTED_REPORT_KEYS,
        "Unknown or missing workload report keys: "
        f"expected={sorted(EXPECTED_REPORT_KEYS)} actual={sorted(report)}",
    )
    _require(report["schema"] == REPORT_SCHEMA, f"Unknown workload schema: {report['schema']!r}")
    _require(report["scopeId"] == SCOPE_ID, f"Unknown workload scope: {report['scopeId']!r}")
    _require(report["status"] == "inventory-complete", f"Workload status is not complete: {report['status']!r}")
    _require(report["inventoryComplete"] is True, "inventoryComplete must be true")
    _require(report["parseAnomalies"] == [], "Parse anomalies are not allowed")
    _require(report["excludedPluginNames"] == ["FNVR.esp"], "Unexpected excluded plugin set")
    _require(report["plugins"] == _expected_plugin_rows(), "Official plugin provenance mismatch")
    _require(
        report["dispositionSchema"].get("allowed") == list(ALLOWED_DISPOSITIONS)
        and report["dispositionSchema"].get("default") == "uncovered",
        "Workload disposition schema mismatch",
    )

    claimed_canonical = report["canonicalSha256"]
    canonical_payload = dict(report)
    canonical_payload.pop("canonicalSha256")
    recomputed = _canonical_digest(canonical_payload)
    _require(
        claimed_canonical == pins.canonical_sha256,
        f"Workload canonical SHA-256 mismatch: {claimed_canonical}",
    )
    _require(
        recomputed == claimed_canonical,
        f"Workload internal canonical SHA-256 does not reproduce: {recomputed}",
    )
    summary = report["summary"]
    _require(summary["parseAnomalyRows"] == 0, "Summary reports parse anomalies")
    _require(summary["disposedWorkloadBites"] == 0, "Input already assigns dispositions")
    _require(summary["workloadBites"] == len(report["workloadBites"]), "Workload bite count mismatch")
    _require(summary["unresolvedRows"] == len(report["unresolved"]), "Unresolved row count mismatch")
    return report


def load_pinned_row_schema(path: Path, expected_sha256: str = FROZEN_ROW_SCHEMA_SHA256) -> dict:
    try:
        raw = path.read_bytes()
        schema = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise LedgerError(f"Cannot read ledger row schema: {error}") from error
    actual_sha = _sha256(raw)
    _require(actual_sha == expected_sha256, f"Ledger row schema SHA-256 mismatch: {actual_sha}")
    _require(schema.get("$id") == ROW_SCHEMA_ID, f"Unknown ledger row schema: {schema.get('$id')!r}")
    dispositions = schema["properties"]["implementation"]["properties"]["disposition"]["enum"]
    _require(dispositions == list(ALLOWED_DISPOSITIONS), "Ledger schema disposition enum mismatch")
    return schema


def _matches_json_type(value, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    raise LedgerError(f"Unsupported JSON Schema type in pinned row schema: {expected}")


def validate_schema_instance(value, schema: Mapping, path: str = "row") -> None:
    """Validate the exact JSON Schema features used by the pinned row schema."""

    if "const" in schema:
        _require(value == schema["const"], f"{path}: const mismatch")
    if "enum" in schema:
        _require(value in schema["enum"], f"{path}: value {value!r} is outside enum")
    expected_type = schema.get("type")
    if expected_type is not None:
        types = [expected_type] if isinstance(expected_type, str) else expected_type
        _require(
            any(_matches_json_type(value, item) for item in types),
            f"{path}: expected JSON type {types}, got {type(value).__name__}",
        )
    if isinstance(value, dict):
        required = schema.get("required", [])
        missing = sorted(set(required) - set(value))
        _require(not missing, f"{path}: missing required keys {missing}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extras = sorted(set(value) - set(properties))
            _require(not extras, f"{path}: additional properties {extras}")
        for key, child in value.items():
            if key in properties:
                validate_schema_instance(child, properties[key], f"{path}.{key}")
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            validate_schema_instance(item, schema["items"], f"{path}[{index}]")
    if isinstance(value, str):
        if "minLength" in schema:
            _require(len(value) >= schema["minLength"], f"{path}: string is too short")
        if "pattern" in schema:
            _require(re.search(schema["pattern"], value) is not None, f"{path}: pattern mismatch")
    if isinstance(value, int) and not isinstance(value, bool) and "minimum" in schema:
        _require(value >= schema["minimum"], f"{path}: value is below minimum")


def _new_observation() -> dict:
    return {
        "authoredOccurrences": 0,
        "owners": set(),
        "recordFamilies": set(),
        "sourcePlugins": set(),
    }


def reconstruct_observations(report: Mapping) -> dict[tuple[str, str], dict]:
    records: dict[str, dict] = {}
    for record in report["records"]:
        record_id = record.get("id")
        _require(isinstance(record_id, str) and record_id, "Record row has no stable id")
        _require(record_id not in records, f"Duplicate record id: {record_id}")
        records[record_id] = record

    observations: dict[tuple[str, str], dict] = {}

    def add(kind: str, key, owner: str) -> None:
        _require(kind in KIND_POLICY, f"Unknown reconstructed bite kind: {kind}")
        _require(isinstance(owner, str) and owner in records, f"Unknown bite owner: {owner!r}")
        normalized_key = str(key)
        _require(normalized_key, f"Empty bite key for {kind}")
        record = records[owner]
        record_type = record.get("recordType")
        source_plugin = record.get("sourcePlugin")
        _require(isinstance(record_type, str) and record_type, f"Missing record family for {owner}")
        _require(isinstance(source_plugin, str) and source_plugin, f"Missing source plugin for {owner}")
        observation = observations.setdefault((kind, normalized_key), _new_observation())
        observation["authoredOccurrences"] += 1
        observation["owners"].add(owner)
        observation["recordFamilies"].add(record_type)
        observation["sourcePlugins"].add(source_plugin)

    for blob in report["compiledBlobs"]:
        owner = blob["owner"]
        for frame in blob["frames"]:
            add("compiled-opcode", frame["opcode"], owner)
            if "eventOpcode" in frame:
                add("compiled-event", frame["eventOpcode"], owner)
    for blob in report["sourceBlobs"]:
        for command in blob["commandCandidates"]:
            add("source-command", command["token"], blob["owner"])
    for condition in report["conditions"]:
        add("condition-function", condition["functionId"], condition["owner"])
        add("condition-run-on", condition["runOnName"], condition["owner"])
    for segment in report["scriptSegments"]:
        add("script-context", segment["context"], segment["owner"])
    for attachment in report["scriptAttachments"]:
        add("script-attachment-owner", attachment["ownerRecordType"], attachment["owner"])
    return observations


def _validated_input_bites(report: Mapping, observations: Mapping) -> list[dict]:
    bites = report["workloadBites"]
    _require(isinstance(bites, list), "workloadBites must be an array")
    seen_ids: set[str] = set()
    seen_keys: set[tuple[str, str]] = set()
    previous_key: tuple[str, str] | None = None
    for index, bite in enumerate(bites):
        _require(isinstance(bite, dict), f"workloadBites[{index}] must be an object")
        _require(
            frozenset(bite) == EXPECTED_WORKLOAD_BITE_KEYS,
            f"workloadBites[{index}] has unknown or missing keys",
        )
        kind = bite["kind"]
        key = bite["key"]
        _require(kind in KIND_POLICY, f"Unknown workload bite kind: {kind!r}")
        _require(isinstance(key, str) and key, f"Invalid workload bite key at row {index}")
        pair = (kind, key)
        expected_id = f"{kind}:{key}"
        _require(bite["id"] == expected_id, f"Unstable workload bite id: {bite['id']!r}")
        _require(bite["id"] not in seen_ids, f"Duplicate workload bite id: {bite['id']}")
        _require(pair not in seen_keys, f"Duplicate workload bite key: {pair}")
        _require(previous_key is None or previous_key < pair, f"Workload bites are not strictly ordered at {pair}")
        previous_key = pair
        seen_ids.add(bite["id"])
        seen_keys.add(pair)
        _require(bite["disposition"] == "uncovered", f"Input bite assigns parity disposition: {bite['id']}")
        _require(bite["implementationArtifacts"] == [], f"Input bite has implementation artifacts: {bite['id']}")
        _require(bite["evidence"] == [], f"Input bite has evidence: {bite['id']}")
        _require(bite["notes"] == "", f"Input bite has unreviewed notes: {bite['id']}")
        observation = observations.get(pair)
        _require(observation is not None, f"Dropped detailed observation for {bite['id']}")
        _require(
            bite["authoredOccurrences"] == observation["authoredOccurrences"],
            f"Authored occurrence mismatch for {bite['id']}",
        )
        _require(
            bite["affectedRecords"] == len(observation["owners"]),
            f"Affected-record mismatch for {bite['id']}",
        )
    extra = sorted(set(observations) - seen_keys)
    missing = sorted(seen_keys - set(observations))
    _require(not extra and not missing, f"Observation coverage mismatch: extra={extra[:5]} missing={missing[:5]}")
    _require(len(bites) == report["summary"]["workloadBites"], "Summary/input bite count mismatch")
    return bites


def _ledger_row(bite: Mapping, observation: Mapping, report_sha: str) -> dict:
    kind = bite["kind"]
    policy = KIND_POLICY[kind]
    variants = [
        f"authored-occurrences={bite['authoredOccurrences']}",
        f"affected-records={bite['affectedRecords']}",
        *(["classification=lexical-candidate"] if kind == "source-command" else []),
        *[f"record-family={value}" for value in sorted(observation["recordFamilies"])],
        *[f"source-plugin={value}" for value in sorted(observation["sourcePlugins"])],
    ]
    return {
        "rowId": f"fnv-geck:{bite['id']}",
        "scopeId": SCOPE_ID,
        "biteKind": policy["biteKind"],
        "source": {
            "owner": f"geck-workload:{report_sha}",
            "identity": bite["id"],
            "byteOffset": None,
            "byteSize": None,
            "winning": True,
        },
        "category": f"geck-{kind}",
        "dependencies": list(policy["dependencies"]),
        "variants": variants,
        "implementation": {
            "disposition": "uncovered",
            "handlerPath": None,
            "rationale": "Inventory only; no implementation or parity evidence has been reviewed.",
        },
        "retailContract": {
            "preconditions": [],
            "actions": [],
            "stateDelta": {},
            "lifecycle": [],
            "persistence": [],
            "timing": {},
        },
        "status": "cataloged",
        "evidence": {"manifestSha256": None},
    }


def build_ledger(
    report: Mapping,
    row_schema: Mapping,
    *,
    report_raw_sha256: str,
    report_bytes: int,
    row_schema_sha256: str,
    generator_sha256: str,
) -> dict:
    observations = reconstruct_observations(report)
    bites = _validated_input_bites(report, observations)
    rows = [
        _ledger_row(bite, observations[(bite["kind"], bite["key"])], report["canonicalSha256"])
        for bite in bites
    ]
    row_ids = [row["rowId"] for row in rows]
    _require(row_ids == sorted(row_ids), "Generated row IDs are not in canonical order")
    _require(len(row_ids) == len(set(row_ids)), "Generated row IDs are not unique")
    for index, row in enumerate(rows):
        validate_schema_instance(row, row_schema, f"rows[{index}]")
        _require(row["implementation"]["disposition"] == "uncovered", "Generator assigned a disposition")
        _require(row["status"] != "pass", "Generator awarded parity")
        _require(row["evidence"]["manifestSha256"] is None, "Generator attached proof evidence")

    by_source_family = Counter(bite["kind"] for bite in bites)
    by_bite_kind = Counter(row["biteKind"] for row in rows)
    all_record_families = sorted(
        {family for observation in observations.values() for family in observation["recordFamilies"]}
    )
    ledger = {
        "schema": LEDGER_SCHEMA,
        "scopeId": SCOPE_ID,
        "rowSchema": {
            "id": ROW_SCHEMA_ID,
            "sha256": row_schema_sha256,
        },
        "generator": {
            "name": "scripts/generate_fnv_bite_ledger.py",
            "sha256": generator_sha256,
        },
        "sourceReport": {
            "schema": REPORT_SCHEMA,
            "bytes": report_bytes,
            "rawSha256": report_raw_sha256,
            "canonicalSha256": report["canonicalSha256"],
            "inventoryComplete": report["inventoryComplete"],
            "plugins": report["plugins"],
        },
        "semantics": {
            "coverage": "Exactly one ledger row per workloadBites equivalence class after reconstruction from detailed artifacts.",
            "counts": "authored-occurrences and affected-records are carried as schema-valid variants and rechecked from artifacts.",
            "sourceFamilies": "record-family and source-plugin variants are derived from every contributing winning owner.",
            "sourceCommands": "source-command rows remain conservative lexical candidates, not resolved GECK command claims.",
            "parity": "Cataloging earns zero parity. Every generated row is uncovered, non-pass, and has no evidence manifest.",
            "paths": "No local filesystem path is serialized.",
        },
        "dispositionPolicy": {
            "allowed": list(ALLOWED_DISPOSITIONS),
            "generated": "uncovered",
        },
        "summary": {
            "inputRows": len(bites),
            "outputRows": len(rows),
            "droppedRows": 0,
            "duplicateInputIds": 0,
            "duplicateRowIds": 0,
            "uncoveredRows": len(rows),
            "parityCreditRows": 0,
            "authoredOccurrences": sum(bite["authoredOccurrences"] for bite in bites),
            "affectedRecordMemberships": sum(bite["affectedRecords"] for bite in bites),
            "sourceRecordFamilies": all_record_families,
            "bySourceFamily": dict(sorted(by_source_family.items())),
            "byBiteKind": dict(sorted(by_bite_kind.items())),
        },
        "rows": rows,
    }
    ledger["canonicalSha256"] = _canonical_digest(ledger)
    validate_ledger(ledger, row_schema)
    return ledger


def validate_ledger(ledger: Mapping, row_schema: Mapping) -> None:
    expected_keys = {
        "canonicalSha256",
        "dispositionPolicy",
        "generator",
        "rowSchema",
        "rows",
        "schema",
        "scopeId",
        "semantics",
        "sourceReport",
        "summary",
    }
    _require(set(ledger) == expected_keys, "Ledger has unknown or missing top-level keys")
    _require(ledger["schema"] == LEDGER_SCHEMA, "Ledger schema mismatch")
    _require(ledger["scopeId"] == SCOPE_ID, "Ledger scope mismatch")
    rows = ledger["rows"]
    _require(isinstance(rows, list), "Ledger rows must be an array")
    row_ids = [row["rowId"] for row in rows]
    _require(row_ids == sorted(row_ids), "Ledger rows are not ordered by stable ID")
    _require(len(row_ids) == len(set(row_ids)), "Ledger row IDs are duplicated")
    for index, row in enumerate(rows):
        validate_schema_instance(row, row_schema, f"rows[{index}]")
        _require(row["implementation"]["disposition"] == "uncovered", "Ledger contains a disposition")
        _require(row["status"] == "cataloged", "Ledger contains a non-cataloged generated row")
        _require(row["evidence"]["manifestSha256"] is None, "Ledger contains evidence")
    summary = ledger["summary"]
    _require(summary["inputRows"] == len(rows) == summary["outputRows"], "Ledger row summary mismatch")
    _require(summary["droppedRows"] == 0, "Ledger reports dropped rows")
    _require(summary["duplicateInputIds"] == 0, "Ledger reports duplicate input IDs")
    _require(summary["duplicateRowIds"] == 0, "Ledger reports duplicate row IDs")
    _require(summary["uncoveredRows"] == len(rows), "Ledger uncovered count mismatch")
    _require(summary["parityCreditRows"] == 0, "Ledger awards parity credit")
    canonical = dict(ledger)
    claimed = canonical.pop("canonicalSha256")
    _require(_canonical_digest(canonical) == claimed, "Ledger canonical SHA-256 does not reproduce")


def generate(
    report_path: Path,
    row_schema_path: Path,
    *,
    report_pins: ReportPins = FROZEN_REPORT_PINS,
    expected_row_schema_sha256: str = FROZEN_ROW_SCHEMA_SHA256,
    generator_path: Path | None = None,
) -> tuple[dict, bytes]:
    report = load_pinned_report(report_path, report_pins)
    row_schema = load_pinned_row_schema(row_schema_path, expected_row_schema_sha256)
    generator_file = (generator_path or Path(__file__)).resolve()
    try:
        generator_sha = _sha256(generator_file.read_bytes())
    except OSError as error:
        raise LedgerError(f"Cannot hash generator: {error}") from error
    ledger = build_ledger(
        report,
        row_schema,
        report_raw_sha256=report_pins.raw_sha256,
        report_bytes=report_pins.bytes,
        row_schema_sha256=expected_row_schema_sha256,
        generator_sha256=generator_sha,
    )
    return ledger, _canonical_bytes(ledger) + b"\n"


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path, help="Pinned GECK workload JSON")
    parser.add_argument(
        "--row-schema",
        type=Path,
        default=repo_root / "catalog" / "fnv-bite-ledger.schema.json",
        help="Pinned bite-ledger row schema",
    )
    parser.add_argument("--output", required=True, type=Path, help="Canonical compact ledger path")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify --output is already byte-identical instead of writing it",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        ledger, encoded = generate(args.report.resolve(), args.row_schema.resolve())
        if args.check:
            try:
                existing = args.output.read_bytes()
            except OSError as error:
                raise LedgerError(f"Cannot read existing ledger: {error}") from error
            _require(existing == encoded, "Existing ledger is not byte-identical to regeneration")
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(encoded)
    except (LedgerError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(
        "FNV bite ledger "
        f"rows={ledger['summary']['outputRows']} "
        f"uncovered={ledger['summary']['uncoveredRows']} "
        f"sha256={ledger['canonicalSha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
