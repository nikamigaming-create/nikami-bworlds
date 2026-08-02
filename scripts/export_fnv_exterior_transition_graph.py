#!/usr/bin/env python3
"""Export the reviewed-policy input for Fallout: New Vegas XTEL transitions.

The exporter is deliberately read-only. It resolves the selected plugin load
order, follows the TES4 GRUP hierarchy to retain source/destination CELL and
WRLD context, then emits one directed edge for every live XTEL-bearing placed
reference. The result is a local artifact because it contains hashes of the
installed licensed masters; only the policy and this exporter are checked in.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import struct
import sys
import zlib
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import export_fnv_parity_corpus as corpus


GRAPH_SCHEMA = "nikami-fnv-exterior-transition-graph/v1"
POLICY_SCHEMA = "nikami-fnv-seamless-exterior-policy/v1"
CELL_INTERIOR = 0x0001
GROUP_WORLD_CHILDREN = 1
CELL_CHILD_GROUP_TYPES = frozenset((6, 8, 9, 10))
PLACED_TYPES = frozenset(("REFR", "ACHR", "ACRE", "PGRE", "PHZD"))


@dataclass(slots=True)
class ParsedRecord:
    form_id: int | None
    rtype: str
    flags: int
    source: corpus.PluginSource
    offset: int
    parent_world: int | None
    parent_cell: int | None
    fields: dict[str, Any]

    @property
    def deleted(self) -> bool:
        return bool(self.flags & corpus.REC_DELETED)


def form_id(value: int | None) -> str | None:
    return None if value is None else f"0x{value:08x}"


def _zstr(value: bytes) -> str:
    return corpus._zstr(value)


def _resolve_form(
    raw: int,
    source: corpus.PluginSource,
    master_indices: Sequence[int],
    record_offset: int,
    context: str,
    diagnostics: Counter[str],
) -> int | None:
    try:
        return corpus._resolve_form_id(raw, source, master_indices, context)
    except corpus.CorpusError:
        allowlist_key = (source.sha256, record_offset, context, raw)
        if allowlist_key not in corpus.ALLOWED_UNRESOLVABLE_FORM_IDS:
            raise
        diagnostics[f"unresolvableReferencedFormId:{context}"] += 1
        return None


def _record_form(
    raw: int,
    source: corpus.PluginSource,
    master_indices: Sequence[int],
    record_offset: int,
    rtype: str,
    diagnostics: Counter[str],
) -> int | None:
    try:
        return corpus._resolve_form_id(raw, source, master_indices, f"{rtype} header")
    except corpus.CorpusError:
        allowlist_key = (source.sha256, record_offset, rtype, raw)
        if allowlist_key not in corpus.ALLOWED_UNRESOLVABLE_FORM_IDS:
            raise
        diagnostics[f"unresolvableRecordFormId:{rtype}"] += 1
        return None


def _payload_for_record(
    data: mmap.mmap,
    source: corpus.PluginSource,
    offset: int,
    rtype: str,
    raw_form: int,
    flags: int,
    payload_start: int,
    payload_end: int,
    diagnostics: Counter[str],
) -> tuple[bytes | mmap.mmap, int, int]:
    if not flags & corpus.REC_COMPRESSED:
        return data, payload_start, payload_end
    if payload_end - payload_start < 4:
        raise corpus.CorpusError(f"Compressed {rtype} is too short in {source.name} at 0x{offset:x}")
    expected_size = corpus._u32(data, payload_start)
    packed = data[payload_start + 4 : payload_end]
    try:
        unpacked = zlib.decompress(packed)
    except zlib.error as error:
        recovery_key = (source.sha256, offset, rtype, raw_form)
        if recovery_key not in corpus.ALLOWED_ZLIB_CHECKSUM_RECOVERIES:
            raise corpus.CorpusError(
                f"Cannot decompress {rtype} in {source.name} at 0x{offset:x}: {error}; "
                "record is not in the frozen checksum-recovery allowlist"
            ) from error
        try:
            unpacked = zlib.decompress(packed[2:-4], -15)
        except zlib.error as recovery_error:
            raise corpus.CorpusError(
                f"Cannot recover compressed {rtype} in {source.name} at 0x{offset:x}: {recovery_error}"
            ) from error
        diagnostics[f"recoveredZlibChecksum:{rtype}"] += 1
    if len(unpacked) != expected_size:
        raise corpus.CorpusError(
            f"Decompressed size mismatch for {rtype} in {source.name} at 0x{offset:x}: "
            f"{len(unpacked)} != {expected_size}"
        )
    return unpacked, 0, len(unpacked)


def _parse_fields(
    source: corpus.PluginSource,
    rtype: str,
    payload: bytes | mmap.mmap,
    payload_start: int,
    payload_end: int,
    master_indices: Sequence[int],
    record_offset: int,
    diagnostics: Counter[str],
) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    context = f"{source.name}:{rtype}:0x{record_offset:x}"
    for name, subrecord_offset, size in corpus._subrecords(payload, payload_start, payload_end, context):
        raw = bytes(payload[subrecord_offset : subrecord_offset + size])
        if name == b"EDID":
            fields["editorId"] = _zstr(raw)
        elif name == b"FULL" and not source.localized:
            fields["fullName"] = _zstr(raw)
        elif rtype == "WRLD" and name == b"MODL":
            fields["model"] = _zstr(raw)
        elif rtype == "CELL" and name == b"DATA" and raw:
            fields["cellFlags"] = raw[0]
        elif rtype == "CELL" and name == b"XCLC" and len(raw) >= 8:
            fields["grid"] = list(struct.unpack_from("<ii", raw, 0))
        elif rtype == "DOOR" and name == b"MODL":
            fields["model"] = _zstr(raw)
        elif rtype == "DOOR" and name == b"SCRI" and len(raw) >= 4:
            fields["script"] = _resolve_form(
                corpus._u32(raw, 0),
                source,
                master_indices,
                record_offset,
                "DOOR.SCRI",
                diagnostics,
            )
        elif rtype in PLACED_TYPES and name == b"NAME" and len(raw) >= 4:
            fields["base"] = _resolve_form(
                corpus._u32(raw, 0),
                source,
                master_indices,
                record_offset,
                f"{rtype}.NAME",
                diagnostics,
            )
        elif rtype in PLACED_TYPES and name == b"DATA" and len(raw) >= 24:
            fields["position"] = list(struct.unpack_from("<fff", raw, 0))
            fields["rotation"] = list(struct.unpack_from("<fff", raw, 12))
        elif rtype in PLACED_TYPES and name == b"SCRI" and len(raw) >= 4:
            fields["script"] = _resolve_form(
                corpus._u32(raw, 0),
                source,
                master_indices,
                record_offset,
                f"{rtype}.SCRI",
                diagnostics,
            )
        elif rtype in PLACED_TYPES and name == b"XESP" and len(raw) >= 8:
            fields["enableParent"] = _resolve_form(
                corpus._u32(raw, 0),
                source,
                master_indices,
                record_offset,
                f"{rtype}.XESP",
                diagnostics,
            )
            fields["enableParentFlags"] = corpus._u32(raw, 4)
        elif rtype in PLACED_TYPES and name == b"XLOC" and len(raw) >= 8:
            fields["lock"] = {
                "level": struct.unpack_from("<b", raw, 0)[0],
                "flags": raw[1],
                "key": _resolve_form(
                    corpus._u32(raw, 4),
                    source,
                    master_indices,
                    record_offset,
                    f"{rtype}.XLOC",
                    diagnostics,
                ),
            }
        elif rtype in PLACED_TYPES and name == b"XTEL":
            if len(raw) < 28:
                diagnostics[f"malformedXTEL:{rtype}"] += 1
                fields["malformedXtelBytes"] = len(raw)
                continue
            fields["xtel"] = {
                "destinationRef": _resolve_form(
                    corpus._u32(raw, 0),
                    source,
                    master_indices,
                    record_offset,
                    f"{rtype}.XTEL",
                    diagnostics,
                ),
                "position": list(struct.unpack_from("<fff", raw, 4)),
                "rotation": list(struct.unpack_from("<fff", raw, 16)),
                "flags": corpus._u32(raw, 28) if len(raw) >= 32 else 0,
                "destinationCellHint": (
                    _resolve_form(
                        corpus._u32(raw, 32),
                        source,
                        master_indices,
                        record_offset,
                        f"{rtype}.XTEL.destinationCellHint",
                        diagnostics,
                    )
                    if len(raw) >= 36
                    else None
                ),
            }
    return fields


def _parse_plugin(
    source: corpus.PluginSource,
    by_name: Mapping[str, corpus.PluginSource],
) -> tuple[list[ParsedRecord], Counter[str]]:
    diagnostics: Counter[str] = Counter()
    records: list[ParsedRecord] = []
    master_indices = corpus._master_indices(source, by_name)
    with source.path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        first_size = corpus._u32(data, 4)
        first_end = source.header_size + first_size

        def walk(start: int, end: int, current_world: int | None, current_cell: int | None) -> None:
            offset = start
            while offset < end:
                if offset + source.header_size > end:
                    raise corpus.CorpusError(f"Truncated record header in {source.name} at 0x{offset:x}")
                signature = bytes(data[offset : offset + 4])
                if signature == b"GRUP":
                    group_size = corpus._u32(data, offset + 4)
                    group_end = offset + group_size
                    if group_size < source.header_size or group_end > end:
                        raise corpus.CorpusError(f"Malformed GRUP in {source.name} at 0x{offset:x}")
                    group_type = corpus._u32(data, offset + 12)
                    child_world = current_world
                    child_cell = current_cell
                    if group_type == GROUP_WORLD_CHILDREN:
                        child_world = _resolve_form(
                            corpus._u32(data, offset + 8),
                            source,
                            master_indices,
                            offset,
                            "GRUP.world",
                            diagnostics,
                        )
                        child_cell = None
                    elif group_type in CELL_CHILD_GROUP_TYPES:
                        child_cell = _resolve_form(
                            corpus._u32(data, offset + 8),
                            source,
                            master_indices,
                            offset,
                            "GRUP.cell",
                            diagnostics,
                        )
                    walk(offset + source.header_size, group_end, child_world, child_cell)
                    offset = group_end
                    continue

                try:
                    rtype = signature.decode("ascii")
                except UnicodeDecodeError as error:
                    raise corpus.CorpusError(f"Invalid record signature in {source.name} at 0x{offset:x}") from error
                payload_size = corpus._u32(data, offset + 4)
                flags = corpus._u32(data, offset + 8)
                raw_form = corpus._u32(data, offset + 12)
                payload_start = offset + source.header_size
                payload_end = payload_start + payload_size
                if payload_end > end:
                    raise corpus.CorpusError(f"{rtype} record overruns {source.name} at 0x{offset:x}")

                if rtype != "TES4":
                    resolved_form = _record_form(
                        raw_form, source, master_indices, offset, rtype, diagnostics
                    )
                    payload, field_start, field_end = _payload_for_record(
                        data,
                        source,
                        offset,
                        rtype,
                        raw_form,
                        flags,
                        payload_start,
                        payload_end,
                        diagnostics,
                    )
                    fields = _parse_fields(
                        source,
                        rtype,
                        payload,
                        field_start,
                        field_end,
                        master_indices,
                        offset,
                        diagnostics,
                    )
                    records.append(
                        ParsedRecord(
                            form_id=resolved_form,
                            rtype=rtype,
                            flags=flags,
                            source=source,
                            offset=offset,
                            parent_world=current_world,
                            parent_cell=current_cell,
                            fields=fields,
                        )
                    )
                    if rtype == "WRLD" and resolved_form is not None:
                        current_world = resolved_form
                        current_cell = None
                    elif rtype == "CELL" and resolved_form is not None:
                        current_cell = resolved_form
                offset = payload_end

        walk(first_end, len(data), None, None)
    return records, diagnostics


def _provenance(record: ParsedRecord) -> dict[str, Any]:
    return {
        "plugin": record.source.name,
        "loadIndex": record.source.load_index,
        "pluginSha256": record.source.sha256,
        "recordOffset": f"0x{record.offset:x}",
    }


def _record_summary(record: ParsedRecord | None) -> dict[str, Any] | None:
    if record is None:
        return None
    result: dict[str, Any] = {
        "formId": form_id(record.form_id),
        "type": record.rtype,
        "editorId": record.fields.get("editorId", ""),
        "fullName": record.fields.get("fullName", ""),
        "provenance": _provenance(record),
    }
    if record.rtype == "DOOR":
        result["model"] = record.fields.get("model", "")
        result["script"] = form_id(record.fields.get("script"))
    return result


def _build_graph_from_records(
    sources: Sequence[corpus.PluginSource],
    parsed_records: Sequence[ParsedRecord],
    diagnostics: Counter[str],
    source_metadata: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    winners: dict[int, ParsedRecord] = {}
    for record in parsed_records:
        if record.form_id is not None:
            winners[record.form_id] = record
    live = {identity: record for identity, record in winners.items() if not record.deleted}
    cells = {identity: record for identity, record in live.items() if record.rtype == "CELL"}
    worlds = {identity: record for identity, record in live.items() if record.rtype == "WRLD"}

    def world_summary(identity: int | None) -> dict[str, Any] | None:
        if identity is None:
            return None
        record = worlds.get(identity)
        if record is None:
            return {"formId": form_id(identity), "resolved": False}
        return {
            "formId": form_id(identity),
            "resolved": True,
            "editorId": record.fields.get("editorId", ""),
            "fullName": record.fields.get("fullName", ""),
            "provenance": _provenance(record),
        }

    def cell_summary(identity: int | None) -> dict[str, Any] | None:
        if identity is None:
            return None
        record = cells.get(identity)
        if record is None:
            return {"formId": form_id(identity), "resolved": False}
        flags = int(record.fields.get("cellFlags", 0))
        exterior = not bool(flags & CELL_INTERIOR)
        return {
            "formId": form_id(identity),
            "resolved": True,
            "editorId": record.fields.get("editorId", ""),
            "fullName": record.fields.get("fullName", ""),
            "isExterior": exterior,
            "grid": record.fields.get("grid") if exterior else None,
            "world": world_summary(record.parent_world) if exterior else None,
            "provenance": _provenance(record),
        }

    def reference_summary(record: ParsedRecord | None) -> dict[str, Any] | None:
        if record is None:
            return None
        base = live.get(record.fields.get("base"))
        cell = cell_summary(record.parent_cell)
        return {
            "formId": form_id(record.form_id),
            "type": record.rtype,
            "base": _record_summary(base),
            "cell": cell,
            "world": cell.get("world") if cell is not None else None,
            "position": record.fields.get("position"),
            "rotation": record.fields.get("rotation"),
            "lock": (
                {
                    "level": record.fields["lock"]["level"],
                    "flags": record.fields["lock"]["flags"],
                    "key": form_id(record.fields["lock"]["key"]),
                }
                if "lock" in record.fields
                else None
            ),
            "script": form_id(record.fields.get("script")),
            "enableParent": form_id(record.fields.get("enableParent")),
            "enableParentFlags": record.fields.get("enableParentFlags", 0),
            "provenance": _provenance(record),
        }

    edges: list[dict[str, Any]] = []
    for identity, record in sorted(live.items()):
        if record.rtype not in PLACED_TYPES or "xtel" not in record.fields:
            continue
        xtel = record.fields["xtel"]
        destination_identity = xtel.get("destinationRef")
        destination_record = live.get(destination_identity)
        destination = reference_summary(destination_record)
        destination_cell_hint = cell_summary(xtel.get("destinationCellHint"))
        source = reference_summary(record)
        assert source is not None

        resolved_destination_cell = (
            destination.get("cell") if destination is not None else destination_cell_hint
        )
        resolved_destination_world = (
            destination.get("world") if destination is not None else (
                resolved_destination_cell.get("world") if resolved_destination_cell is not None else None
            )
        )
        issues: list[str] = []
        if destination_identity is None:
            issues.append("missing-destination-reference")
        elif destination_record is None:
            issues.append("destination-reference-not-found")
        elif destination_record.rtype not in PLACED_TYPES:
            issues.append("destination-is-not-a-placed-reference")
        if source.get("cell") is None or not source["cell"].get("resolved"):
            issues.append("source-cell-not-resolved")
        if resolved_destination_cell is None or not resolved_destination_cell.get("resolved"):
            issues.append("destination-cell-not-resolved")

        source_cell = source.get("cell")
        source_world = source.get("world")
        source_exterior = bool(source_cell and source_cell.get("resolved") and source_cell.get("isExterior"))
        destination_exterior = bool(
            resolved_destination_cell
            and resolved_destination_cell.get("resolved")
            and resolved_destination_cell.get("isExterior")
        )
        source_world_id = source_world.get("formId") if source_world and source_world.get("resolved") else None
        destination_world_id = (
            resolved_destination_world.get("formId")
            if resolved_destination_world and resolved_destination_world.get("resolved")
            else None
        )
        base = source.get("base") or {}
        edge = {
            "edgeId": f"xtel:{form_id(identity)}",
            "source": source,
            "destination": {
                "referenceFormId": form_id(destination_identity),
                "ref": destination,
                "cellHint": destination_cell_hint,
                "cell": resolved_destination_cell,
                "world": resolved_destination_world,
                "position": xtel.get("position"),
                "rotation": xtel.get("rotation"),
                "flags": xtel.get("flags", 0),
            },
            "reverseEdgeId": None,
            "reverseResolution": "missing",
            "classificationHints": {
                "sourceExterior": source_exterior,
                "destinationExterior": destination_exterior,
                "sameWorldspace": (
                    source_world_id is not None
                    and source_world_id == destination_world_id
                ),
                "sourceBaseIsDoor": base.get("type") == "DOOR",
                "sourceHasReferenceScript": source.get("script") is not None,
                "sourceHasDoorBaseScript": base.get("script") is not None,
                "sourceLocked": source.get("lock") is not None,
                "sourceHasEnableParent": source.get("enableParent") is not None,
            },
            "resolution": {
                "status": "resolved" if not issues else "unresolved",
                "issues": issues,
            },
            "provenance": _provenance(record),
            "_sourceIdentity": identity,
            "_destinationIdentity": destination_identity,
        }
        edges.append(edge)

    by_source = {edge["_sourceIdentity"]: edge for edge in edges}
    for edge in edges:
        destination_identity = edge["_destinationIdentity"]
        candidate = by_source.get(destination_identity)
        if candidate is not None and candidate["_destinationIdentity"] == edge["_sourceIdentity"]:
            edge["reverseEdgeId"] = candidate["edgeId"]
            edge["reverseResolution"] = "exact"
        elif destination_identity is not None and candidate is not None:
            edge["reverseResolution"] = "destination-has-nonreturning-xtel"

    unresolved_edges = [
        {"edgeId": edge["edgeId"], "issues": edge["resolution"]["issues"]}
        for edge in edges
        if edge["resolution"]["status"] != "resolved"
    ]
    reverse_pairs = sum(1 for edge in edges if edge["reverseResolution"] == "exact") // 2
    for edge in edges:
        edge.pop("_sourceIdentity")
        edge.pop("_destinationIdentity")

    expected_names = [name.casefold() for name in corpus.OFFICIAL_NAMES]
    actual_names = [source.name.casefold() for source in sources]
    source_summary: dict[str, Any] = {
        "recordSemantics": "last-loaded live record per master-resolved FormID",
        "completeOfficialSet": actual_names == expected_names,
        "pluginLoadOrder": [
            {
                "name": source.name,
                "loadIndex": source.load_index,
                "role": source.role,
                "bytes": source.size,
                "sha256": source.sha256,
            }
            for source in sources
        ],
    }
    if source_metadata:
        source_summary.update(source_metadata)
    graph = {
        "schema": GRAPH_SCHEMA,
        "source": source_summary,
        "counts": {
            "physicalRecords": len(parsed_records),
            "winningRecords": len(winners),
            "liveRecords": len(live),
            "xtelEdges": len(edges),
            "resolvedEdges": len(edges) - len(unresolved_edges),
            "unresolvedEdges": len(unresolved_edges),
            "exactReversePairs": reverse_pairs,
        },
        "diagnostics": dict(sorted(diagnostics.items())),
        "edges": sorted(edges, key=lambda edge: edge["edgeId"]),
        "unresolvedEdges": unresolved_edges,
    }
    canonical_bytes = json.dumps(
        graph, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    graph["canonicalGraphSha256"] = hashlib.sha256(canonical_bytes).hexdigest()
    return graph


def build_transition_graph(
    paths: Sequence[Path], source_metadata: Mapping[str, Any] | None = None
) -> dict[str, Any]:
    """Build a deterministic directed XTEL graph from plugins in load order."""

    sources = corpus.inspect_plugins([Path(path).resolve() for path in paths])
    by_name = {source.name.casefold(): source for source in sources}
    parsed_records: list[ParsedRecord] = []
    diagnostics: Counter[str] = Counter()
    for source in sources:
        records, source_diagnostics = _parse_plugin(source, by_name)
        parsed_records.extend(records)
        diagnostics.update(source_diagnostics)
    return _build_graph_from_records(sources, parsed_records, diagnostics, source_metadata)


def canonical_official_paths_from_config(config_path: Path) -> tuple[list[Path], dict[str, Any]]:
    """Resolve canonical official inputs without mutating a shared runtime profile.

    The selected records are canonical even when a local OpenMW profile has the
    same official plugins in a different order. The differing configured order
    is preserved in the graph so that the result cannot be mistaken for proof
    of that unmodified profile.
    """

    config = corpus.read_openmw_config_sources(config_path)
    configured_order = list(config.content)
    expected_order = list(corpus.OFFICIAL_NAMES)
    configured_folded = [name.casefold() for name in configured_order]
    expected_folded = [name.casefold() for name in expected_order]
    if len(configured_folded) != len(expected_folded) or set(configured_folded) != set(expected_folded):
        raise corpus.CorpusError(
            "Canonical official selection requires exactly the official FNV Ultimate Edition "
            "plugins in the configured profile (no missing, duplicate, or extra content entries)"
        )
    return (
        corpus._resolve_config_entries(expected_order, config.data_roots, "canonical official content"),
        {
            "inputSelection": "canonical-official-from-config",
            "configuredContentOrder": configured_order,
            "configuredContentOrderMatchesFrozen": configured_folded == expected_folded,
        },
    )


def build_policy_template(graph: Mapping[str, Any]) -> dict[str, Any]:
    """Create explicit, non-promotable review rows for every exported edge."""

    source = graph["source"]
    return {
        "schema": POLICY_SCHEMA,
        "reviewStatus": "phase-0-discovery",
        "scope": {
            "edition": "Fallout: New Vegas Ultimate Edition",
            "language": "English",
            "frozenLoadOrder": [item["name"] for item in source["pluginLoadOrder"]],
            "edgeIdentity": "xtel:<source-reference-load-order-form-id>",
            "sourceRecordSemantics": "last-loaded live record per master-resolved FormID",
        },
        "defaults": {
            "classification": "unreviewed",
            "activation": "retain-authored-transition",
            "walkThrough": False,
            "shippingEligible": False,
        },
        "generatedFrom": {
            "graphSchema": graph["schema"],
            "graphSha256": graph["canonicalGraphSha256"],
        },
        "graphDefaults": [
            {
                "graphSchema": graph["schema"],
                "graphSha256": graph["canonicalGraphSha256"],
                "classification": "unreviewed",
                "reviewState": "unreviewed",
                "walkThrough": False,
                "notes": "Generated from the frozen transition graph; visual and gameplay review required.",
            }
        ],
        "edges": [],
    }


def _write_json(path: Path, payload: Mapping[str, Any], force: bool) -> None:
    path = path.resolve()
    if path.exists() and not force:
        raise corpus.CorpusError(f"Refusing to overwrite existing output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    repo_root = SCRIPT_DIRECTORY.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=repo_root / "profiles" / "fallout_new_vegas" / "openmw.cfg",
        help="OpenMW configuration used to resolve content in frozen load order",
    )
    parser.add_argument(
        "--plugin",
        action="append",
        type=Path,
        default=[],
        help="Explicit plugin path in load order; repeat to bypass --config",
    )
    parser.add_argument(
        "--canonical-official-from-config",
        action="store_true",
        help=(
            "Resolve the frozen official order from --config data roots without changing that profile; "
            "the graph records any configured-order mismatch"
        ),
    )
    parser.add_argument("--output", required=True, type=Path, help="New graph JSON output path")
    parser.add_argument(
        "--policy-template",
        type=Path,
        help="Optional new explicit-unreviewed policy template output path",
    )
    parser.add_argument(
        "--require-official-load-order",
        action="store_true",
        help="Fail unless the selected inputs are the frozen official FNV Ultimate Edition order",
    )
    parser.add_argument("--force", action="store_true", help="Allow overwriting an output file")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.plugin and args.canonical_official_from_config:
            raise corpus.CorpusError("--plugin cannot be combined with --canonical-official-from-config")
        source_metadata: Mapping[str, Any] | None = None
        if args.plugin:
            paths = [path.resolve() for path in args.plugin]
        elif args.canonical_official_from_config:
            paths, source_metadata = canonical_official_paths_from_config(args.config)
        else:
            paths = corpus.plugin_paths_from_config(args.config)
        graph = build_transition_graph(paths, source_metadata)
        if args.require_official_load_order and not graph["source"]["completeOfficialSet"]:
            raise corpus.CorpusError(
                "Selected plugins are not the frozen official Fallout: New Vegas Ultimate Edition load order"
            )
        _write_json(args.output, graph, args.force)
        if args.policy_template:
            _write_json(args.policy_template, build_policy_template(graph), args.force)
    except (corpus.CorpusError, OSError, struct.error, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    print(
        json.dumps(
            {
                "output": str(args.output.resolve()),
                "policyTemplate": str(args.policy_template.resolve()) if args.policy_template else None,
                "counts": graph["counts"],
                "canonicalGraphSha256": graph["canonicalGraphSha256"],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
