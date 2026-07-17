#!/usr/bin/env python3
"""Build a strict, capture-keyed Fallout NV/OpenMW Goodsprings comparison.

The comparator deliberately refuses to infer correspondence from image order,
filenames, or contact-sheet grid position.  Both engines must emit the same 37
captureId values and must agree on every identity field before any image pair is
rendered.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from PIL import Image, ImageDraw, ImageFont


EXPECTED_CAPTURE_COUNT = 37
CANONICAL_SHOT_KIND = "front-full-body"
OUTPUT_SCHEMA = "nikami-goodsprings-manifest-comparison/v2"
RETAIL_SCHEMA = "nikami-fnv-goodsprings-full-telemetry/v2"
OPENMW_SCHEMA = "nikami-openmw-goodsprings-actor-batch/v2"

FORM_RE = re.compile(r"0x([0-9a-fA-F]+)")
FIELD_RE = re.compile(r"(?:^|\s)([A-Za-z][A-Za-z0-9]*)=(?:\"([^\"]*)\"|(\S+))")
PART_MATRIX_RE = re.compile(
    r"FNV/ESM4 PART MATRIX AUDIT (?P<actor>.+?) part='(?P<part>[^']*)'"
    r"\s+class=(?P<part_class>[^\s]+)"
)

SEMANTIC_KEYS = (
    "face",
    "eyes",
    "hair",
    "facialHair",
    "leftHand",
    "rightHand",
    "gloves",
    "headgear",
    "bodyOrClothing",
    "weapon",
)


class ContractError(RuntimeError):
    """Raised when evidence cannot be paired without guessing."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def load_json(path: Path, label: str) -> dict[str, Any]:
    require(path.is_file(), f"{label} does not exist: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"Unable to read {label} {path}: {exc}") from exc
    require(isinstance(value, dict), f"{label} must contain a JSON object: {path}")
    return value


def resolve_path(value: Any, owner: Path, label: str, *, must_exist: bool = True) -> Path:
    require(isinstance(value, str) and value.strip(), f"{label} path is missing")
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = owner.parent / candidate
    candidate = candidate.resolve()
    if must_exist:
        require(candidate.is_file(), f"{label} does not exist: {candidate}")
    return candidate


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evidence(path: Path, kind: str) -> dict[str, Any]:
    stat = path.stat()
    return {
        "kind": kind,
        "path": str(path),
        "bytes": stat.st_size,
        "sha256": sha256(path),
    }


def validate_stored_evidence(record: Any, owner: Path, label: str) -> Path:
    require(isinstance(record, dict), f"{label} evidence record is missing")
    path = resolve_path(record.get("path"), owner, label)
    actual = evidence(path, str(record.get("kind") or label))
    if record.get("bytes") is not None:
        require(int(record["bytes"]) == actual["bytes"], f"{label} byte count changed: {path}")
    if record.get("sha256") is not None:
        require(
            str(record["sha256"]).lower() == actual["sha256"],
            f"{label} SHA-256 changed: {path}",
        )
    return path


def is_synthetic_form(value: Any) -> bool:
    text = str(value or "").strip().lower()
    return "object@" in text or "formid:@" in text or text.startswith("@")


def canonical_form(value: Any, label: str) -> str:
    require(value is not None and not isinstance(value, bool), f"{label} form id is missing")
    if isinstance(value, int):
        number = value
    else:
        text = str(value).strip()
        require(not is_synthetic_form(text), f"{label} uses a synthetic reference: {text}")
        match = FORM_RE.search(text)
        require(match is not None, f"{label} is not a form id: {text}")
        number = int(match.group(1), 16)
    require(number >= 0, f"{label} is negative: {number}")
    return f"0x{number & 0x00FFFFFF:08x}"


def canonical_capture_id(row: dict[str, Any], label: str) -> tuple[str, str, str]:
    capture_id = row.get("captureId")
    target_id = row.get("targetId", row.get("id"))
    shot_kind = row.get("shotKind")
    require(isinstance(capture_id, str) and capture_id, f"{label} captureId is missing")
    require(isinstance(target_id, str) and target_id, f"{label} targetId is missing")
    require(isinstance(shot_kind, str) and shot_kind, f"{label} shotKind is missing")
    require(
        capture_id == f"{target_id}::{shot_kind}",
        f"{label} captureId does not encode its target/shot identity: {capture_id}",
    )
    if row.get("id") is not None:
        require(str(row["id"]) == target_id, f"{label} id/targetId mismatch for {capture_id}")
    return capture_id, target_id, shot_kind


def unique_index(rows: Any, key: str, label: str) -> dict[str, dict[str, Any]]:
    require(isinstance(rows, list), f"{label} must be an array")
    index: dict[str, dict[str, Any]] = {}
    for number, row in enumerate(rows, 1):
        require(isinstance(row, dict), f"{label}[{number}] must be an object")
        value = row.get(key)
        require(isinstance(value, str) and value, f"{label}[{number}].{key} is missing")
        require(value not in index, f"{label} contains duplicate {key}: {value}")
        index[value] = row
    return index


def path_key(path: Path) -> str:
    return os.path.normcase(str(path.resolve()))


def validate_retail_manifest(path: Path) -> tuple[dict[str, Any], list[str], Path]:
    manifest = load_json(path, "retail full-telemetry manifest")
    require(manifest.get("schema") == RETAIL_SCHEMA, f"Unexpected retail schema: {manifest.get('schema')!r}")
    require(int(manifest.get("targetCount", -1)) == EXPECTED_CAPTURE_COUNT, "Retail targetCount is not exactly 37")
    require(
        manifest.get("canonicalShotKind") == CANONICAL_SHOT_KIND,
        "Retail manifest is not a canonical front-full-body run",
    )
    rows = manifest.get("rows")
    screenshots = manifest.get("screenshots")
    require(isinstance(rows, list) and len(rows) == EXPECTED_CAPTURE_COUNT, "Retail rows are not exactly 37")
    require(
        isinstance(screenshots, list) and len(screenshots) == EXPECTED_CAPTURE_COUNT,
        "Retail screenshots are not exactly 37",
    )
    require(not manifest.get("failed"), "Retail full-telemetry manifest contains failed targets")

    row_index = unique_index(rows, "captureId", "retail rows")
    screenshot_index = unique_index(screenshots, "captureId", "retail screenshots")
    require(set(row_index) == set(screenshot_index), "Retail row/screenshot captureId sets differ")

    seen_paths: set[str] = set()
    order: list[str] = []
    normalized: dict[str, Any] = {}
    for ordinal, row in enumerate(rows, 1):
        capture_id, target_id, shot_kind = canonical_capture_id(row, f"retail row {ordinal}")
        require(
            shot_kind == CANONICAL_SHOT_KIND,
            f"Retail {capture_id} is stale/noncanonical shot kind {shot_kind!r}; rerun full-body capture",
        )
        order.append(capture_id)
        screenshot = screenshot_index[capture_id]
        shot_capture_id, shot_target_id, shot_shot_kind = canonical_capture_id(
            screenshot, f"retail screenshot {capture_id}"
        )
        require(shot_capture_id == capture_id, f"Retail screenshot capture mismatch: {capture_id}")
        require(shot_target_id == target_id, f"Retail screenshot target mismatch: {capture_id}")
        require(shot_shot_kind == shot_kind, f"Retail screenshot shot mismatch: {capture_id}")

        authored_ref = canonical_form(row.get("authoredRef", row.get("reference")), f"retail {capture_id} authoredRef")
        actual_ref = canonical_form(row.get("actualRuntimeRef"), f"retail {capture_id} actualRuntimeRef")
        base = canonical_form(row.get("base"), f"retail {capture_id} base")
        expected_base = canonical_form(row.get("expectedBase", row.get("base")), f"retail {capture_id} expectedBase")
        category = str(row.get("category") or "")
        require(category, f"Retail category is missing for {capture_id}")
        require(authored_ref != "0x00000000" and base != "0x00000000", f"Retail identity is zero for {capture_id}")
        require(actual_ref == authored_ref, f"Retail actual/authored reference mismatch for {capture_id}")
        require(base == expected_base, f"Retail base/expectedBase mismatch for {capture_id}")
        require(row.get("identityMode") == "authored-reference", f"Retail identity mode is not authored-reference: {capture_id}")
        require(row.get("passed") is True, f"Retail telemetry row did not pass: {capture_id}")

        for field, expected in (("authoredRef", authored_ref), ("actualRuntimeRef", authored_ref), ("base", base)):
            require(
                canonical_form(screenshot.get(field), f"retail screenshot {capture_id} {field}") == expected,
                f"Retail row/screenshot {field} mismatch for {capture_id}",
            )
        require(
            screenshot.get("identityMode") == "authored-reference",
            f"Retail screenshot identity mode is not authored-reference: {capture_id}",
        )

        screenshot_path = resolve_path(row.get("screenshot"), path, f"retail screenshot {capture_id}")
        manifest_screenshot_path = resolve_path(
            screenshot.get("path"), path, f"retail screenshot manifest path {capture_id}"
        )
        require(screenshot_path == manifest_screenshot_path, f"Retail screenshot path mismatch for {capture_id}")
        key = path_key(screenshot_path)
        require(key not in seen_paths, f"Retail screenshot path is duplicated: {screenshot_path}")
        seen_paths.add(key)

        normalized[capture_id] = {
            "captureId": capture_id,
            "targetId": target_id,
            "category": category,
            "authoredRef": authored_ref,
            "base": base,
            "shotKind": shot_kind,
            "screenshot": screenshot_path,
            "manifestRow": row,
        }

    evidence_object = manifest.get("evidence")
    require(isinstance(evidence_object, dict), "Retail manifest evidence object is missing")
    jsonl_path = validate_stored_evidence(evidence_object.get("capture"), path, "retail JSONL")
    stored_screenshots = evidence_object.get("screenshots")
    require(
        isinstance(stored_screenshots, list) and len(stored_screenshots) == EXPECTED_CAPTURE_COUNT,
        "Retail screenshot evidence is not exactly 37",
    )
    stored_paths = {
        path_key(validate_stored_evidence(item, path, f"retail screenshot evidence {number}"))
        for number, item in enumerate(stored_screenshots, 1)
    }
    require(stored_paths == seen_paths, "Retail screenshot evidence paths differ from keyed rows")

    manifest["_normalizedRows"] = normalized
    return manifest, order, jsonl_path


def validate_openmw_manifest(path: Path, retail_roster_hash: str | None) -> tuple[dict[str, Any], Path, Path]:
    batch = load_json(path, "OpenMW batch index")
    require(batch.get("schema") == OPENMW_SCHEMA, f"Unexpected OpenMW batch schema: {batch.get('schema')!r}")
    require(int(batch.get("processCount", -1)) == 1, "OpenMW actor batch was not captured in one process")
    require(batch.get("identityMode") == "authored-reference", "OpenMW batch identity mode is not authored-reference")
    require(
        batch.get("canonicalShotKind") == CANONICAL_SHOT_KIND,
        "OpenMW batch is not a canonical front-full-body run",
    )
    rows = batch.get("rows")
    require(isinstance(rows, list) and len(rows) == EXPECTED_CAPTURE_COUNT, "OpenMW rows are not exactly 37")
    if retail_roster_hash:
        require(
            str(batch.get("canonicalRosterSha256") or "").lower() == retail_roster_hash.lower(),
            "Retail/OpenMW canonical-roster hashes differ",
        )

    capture_manifest_path = resolve_path(batch.get("manifest"), path, "OpenMW capture manifest")
    log_path = resolve_path(batch.get("log"), path, "OpenMW telemetry log")
    capture_manifest = load_json(capture_manifest_path, "OpenMW capture manifest")
    captures = capture_manifest.get("screenshots")
    require(
        isinstance(captures, list) and len(captures) == EXPECTED_CAPTURE_COUNT,
        "OpenMW capture manifest screenshots are not exactly 37",
    )
    require(capture_manifest.get("status") == "captured-native", "OpenMW capture manifest did not finish as captured-native")

    capture_paths: dict[str, dict[str, Any]] = {}
    native_paths: set[str] = set()
    for number, capture in enumerate(captures, 1):
        require(isinstance(capture, dict), f"OpenMW capture manifest screenshot {number} is not an object")
        require(capture.get("source") == "openmw-native-screenshot", "OpenMW comparison requires native screenshots")
        copied = resolve_path(capture.get("path"), capture_manifest_path, f"OpenMW copied screenshot {number}")
        copied_key = path_key(copied)
        require(copied_key not in capture_paths, f"OpenMW capture manifest duplicates screenshot path: {copied}")
        capture_paths[copied_key] = capture
        native_raw = capture.get("nativePath")
        require(isinstance(native_raw, str) and native_raw, f"OpenMW native screenshot path {number} is missing")
        native_key = os.path.normcase(os.path.abspath(native_raw))
        require(native_key not in native_paths, f"OpenMW native screenshot path is duplicated: {native_raw}")
        native_paths.add(native_key)

    normalized: dict[str, Any] = {}
    seen_screenshots: set[str] = set()
    for ordinal, row in enumerate(rows, 1):
        require(isinstance(row, dict), f"OpenMW row {ordinal} is not an object")
        capture_id, target_id, shot_kind = canonical_capture_id(row, f"OpenMW row {ordinal}")
        require(
            shot_kind == CANONICAL_SHOT_KIND,
            f"OpenMW {capture_id} is not canonical shot kind {CANONICAL_SHOT_KIND!r}",
        )
        require(capture_id not in normalized, f"OpenMW rows duplicate captureId: {capture_id}")
        authored_ref = canonical_form(row.get("authoredRef"), f"OpenMW {capture_id} authoredRef")
        actual_raw = row.get("actualRuntimeRef")
        require(not is_synthetic_form(actual_raw), f"OpenMW {capture_id} uses a synthetic actual reference: {actual_raw}")
        actual_ref = canonical_form(actual_raw, f"OpenMW {capture_id} actualRuntimeRef")
        reference = canonical_form(row.get("reference"), f"OpenMW {capture_id} reference")
        base = canonical_form(row.get("base"), f"OpenMW {capture_id} base")
        runtime_base = canonical_form(row.get("runtimeBase"), f"OpenMW {capture_id} runtimeBase")
        category = str(row.get("category") or "")
        require(category, f"OpenMW category is missing for {capture_id}")
        require(authored_ref != "0x00000000" and base != "0x00000000", f"OpenMW identity is zero for {capture_id}")
        require(actual_ref == authored_ref == reference, f"OpenMW authored/actual/reference mismatch for {capture_id}")
        require(base == runtime_base, f"OpenMW base/runtimeBase mismatch for {capture_id}")
        require(row.get("identityMode") == "authored-reference", f"OpenMW identity mode is not authored-reference: {capture_id}")
        require(row.get("identityMatchesAuthored") is True, f"OpenMW authored identity gate failed: {capture_id}")

        screenshot = resolve_path(row.get("screenshot"), path, f"OpenMW screenshot {capture_id}")
        screenshot_key = path_key(screenshot)
        require(screenshot_key not in seen_screenshots, f"OpenMW screenshot path is duplicated: {screenshot}")
        require(screenshot_key in capture_paths, f"OpenMW row screenshot is absent from capture manifest: {screenshot}")
        seen_screenshots.add(screenshot_key)
        capture = capture_paths[screenshot_key]
        require(
            os.path.normcase(os.path.abspath(str(row.get("screenshotNativePath") or "")))
            == os.path.normcase(os.path.abspath(str(capture.get("nativePath") or ""))),
            f"OpenMW native screenshot path mismatch for {capture_id}",
        )

        requested_frame = int(row.get("requestedFrame"))
        actual_frame = int(row.get("actualFrame"))
        frame_drift = int(row.get("frameDrift"))
        require(actual_frame >= requested_frame, f"OpenMW captured {capture_id} before its requested frame")
        require(frame_drift == actual_frame - requested_frame, f"OpenMW frameDrift is inconsistent for {capture_id}")
        require(int(row.get("screenshotFrame")) == actual_frame, f"OpenMW screenshotFrame is not actualFrame: {capture_id}")

        normalized[capture_id] = {
            "captureId": capture_id,
            "targetId": target_id,
            "category": category,
            "authoredRef": authored_ref,
            "base": base,
            "shotKind": shot_kind,
            "screenshot": screenshot,
            "requestedFrame": requested_frame,
            "actualFrame": actual_frame,
            "frameDrift": frame_drift,
            "manifestRow": row,
        }

    require(seen_screenshots == set(capture_paths), "OpenMW batch rows do not cover every capture-manifest screenshot")
    scheduled = sorted(normalized.values(), key=lambda item: item["requestedFrame"])
    requested_frames = [item["requestedFrame"] for item in scheduled]
    actual_frames = [item["actualFrame"] for item in scheduled]
    require(len(set(requested_frames)) == EXPECTED_CAPTURE_COUNT, "OpenMW requested frames are duplicated")
    require(len(set(actual_frames)) == EXPECTED_CAPTURE_COUNT, "OpenMW actual frames are duplicated")
    require(actual_frames == sorted(actual_frames), "OpenMW actual screenshot frames are nonmonotonic")
    for current, following in zip(scheduled, scheduled[1:]):
        require(
            current["actualFrame"] < following["requestedFrame"],
            f"OpenMW capture crossed actor windows: {current['captureId']} -> {following['captureId']}",
        )

    batch["_normalizedRows"] = normalized
    batch["_captureManifest"] = capture_manifest
    return batch, capture_manifest_path, log_path


def strip_json_array_property(line: str, property_name: str) -> tuple[str, bool]:
    """Replace a JSON array value with null without decoding its elements."""

    marker = json.dumps(property_name) + ":"
    marker_index = line.find(marker)
    if marker_index < 0:
        return line, False
    start = marker_index + len(marker)
    while start < len(line) and line[start].isspace():
        start += 1
    require(start < len(line) and line[start] == "[", f"{property_name} is not an array")
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(line)):
        char = line[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return line[:start] + "null" + line[index + 1 :], True
    raise ContractError(f"Unterminated {property_name} array in retail JSONL")


def semantic_flags(texts: Iterable[str]) -> dict[str, list[str]]:
    hits: dict[str, set[str]] = {key: set() for key in SEMANTIC_KEYS}
    for raw in texts:
        if raw is None:
            continue
        text = str(raw)
        lower = text.lower().replace("\\", "/")
        if any(token in lower for token in ("face", "head", "mouth", "teeth", "tongue", "brow")):
            hits["face"].add(text)
        if "eye" in lower:
            hits["eyes"].add(text)
        if "hair" in lower and "beard" not in lower:
            hits["hair"].add(text)
        if any(token in lower for token in ("beard", "mustache", "moustache", "goatee", "facialhair")):
            hits["facialHair"].add(text)
        if "lefthand" in lower or "left hand" in lower or "left_hand" in lower:
            hits["leftHand"].add(text)
        if "righthand" in lower or "right hand" in lower or "right_hand" in lower:
            hits["rightHand"].add(text)
        if "glove" in lower or "gauntlet" in lower:
            hits["gloves"].add(text)
        if any(token in lower for token in ("headgear", "helmet", "cowboyhat", "/hat", " hat", "cap:")):
            hits["headgear"].add(text)
        if any(
            token in lower
            for token in (
                "upperbody",
                "lowerbody",
                "body",
                "armor",
                "clothing",
                "outfit",
                "shirt",
                "jacket",
                "pants",
                "dress",
                "robe",
                "boot",
            )
        ):
            hits["bodyOrClothing"].add(text)
        if any(
            token in lower
            for token in (
                "weapon",
                "pistol",
                "rifle",
                "revolver",
                "shotgun",
                "scattergun",
                "minigun",
                "gun:",
                "357",
                "9mm",
                "10mm",
                "knife",
                "sword",
                "machete",
            )
        ):
            hits["weapon"].add(text)
    return {key: sorted(values, key=str.casefold) for key, values in hits.items()}


def parse_retail_geometry(
    jsonl_path: Path, rows_by_capture: dict[str, dict[str, Any]]
) -> dict[str, dict[str, Any]]:
    expected_by_ref = {row["authoredRef"]: row for row in rows_by_capture.values()}
    shapes: dict[str, list[dict[str, Any]]] = defaultdict(list)
    statuses: dict[str, list[dict[str, Any]]] = defaultdict(list)
    stripped_vertex_arrays = 0

    # Retail occasionally records raw non-UTF-8 bytes in diagnostic node-name
    # strings. Replacement preserves the JSON record and every numeric/form
    # field used by the strict geometry contract without dropping the event.
    with jsonl_path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            if '"event":"actor-geometry"' in line:
                sanitized, stripped = strip_json_array_property(line, "vertices")
                require(stripped, f"Retail actor-geometry line {line_number} has no vertices array")
                stripped_vertex_arrays += 1
                try:
                    event = json.loads(sanitized)
                except json.JSONDecodeError as exc:
                    raise ContractError(f"Invalid retail actor-geometry JSON at line {line_number}: {exc}") from exc
                require(event.get("vertices") is None, "Retail geometry vertices were unexpectedly materialized")
                ref = canonical_form(event.get("refForm"), f"retail geometry line {line_number} refForm")
                require(ref in expected_by_ref, f"Retail geometry has an out-of-contract ref at line {line_number}: {ref}")
                base = canonical_form(event.get("baseForm"), f"retail geometry line {line_number} baseForm")
                require(base == expected_by_ref[ref]["base"], f"Retail geometry base mismatch for {ref}")
                require(event.get("complete") is True, f"Retail geometry is incomplete for {ref} at line {line_number}")
                name = event.get("name")
                require(isinstance(name, str) and name, f"Retail geometry name is missing at line {line_number}")
                shapes[ref].append(
                    {
                        "name": name,
                        "runtimeType": event.get("runtimeType"),
                        "shaderPropertyType": event.get("shaderPropertyType"),
                        "vertexCount": int(event.get("vertexCount", 0)),
                        "fnv1a32": event.get("fnv1a32"),
                    }
                )
            elif '"event":"actor-geometry-status"' in line:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ContractError(f"Invalid retail geometry-status JSON at line {line_number}: {exc}") from exc
                ref = canonical_form(event.get("refForm"), f"retail geometry status line {line_number} refForm")
                require(ref in expected_by_ref, f"Retail geometry status has an out-of-contract ref: {ref}")
                base = canonical_form(event.get("baseForm"), f"retail geometry status line {line_number} baseForm")
                require(base == expected_by_ref[ref]["base"], f"Retail geometry status base mismatch for {ref}")
                statuses[ref].append(event)

    result: dict[str, dict[str, Any]] = {}
    for ref, expected in expected_by_ref.items():
        ref_shapes = shapes.get(ref, [])
        ref_statuses = statuses.get(ref, [])
        require(ref_shapes, f"Retail geometry is missing for {expected['captureId']}")
        require(len(ref_statuses) == 1, f"Retail geometry status count is not one for {expected['captureId']}")
        status = ref_statuses[0]
        require(int(status.get("emittedShapes", -1)) == len(ref_shapes), f"Retail geometry count mismatch for {expected['captureId']}")
        for field in (
            "pointerReadFailures",
            "dataReadFailures",
            "invalidDataLayouts",
            "vertexReadFailures",
        ):
            require(int(status.get(field, -1)) == 0, f"Retail {field} is nonzero for {expected['captureId']}")
        require(status.get("traversalFault") is False, f"Retail traversal fault for {expected['captureId']}")
        manifest_count = expected["manifestRow"].get("geometryShapes")
        if manifest_count is not None:
            require(int(manifest_count) == len(ref_shapes), f"Retail manifest/JSONL geometry count mismatch for {expected['captureId']}")
        names = [item["name"] for item in ref_shapes]
        result[ref] = {
            "shapeCount": len(ref_shapes),
            "uniqueShapeCount": len(set(names)),
            "names": names,
            "shapes": ref_shapes,
            "status": {
                key: status.get(key)
                for key in (
                    "visitedNodes",
                    "geometryCandidates",
                    "emittedShapes",
                    "pointerReadFailures",
                    "dataReadFailures",
                    "invalidDataLayouts",
                    "vertexReadFailures",
                    "traversalFault",
                )
            },
            "semantics": semantic_flags(names),
            "vertexArraysMaterialized": False,
        }
    require(stripped_vertex_arrays == sum(len(value) for value in shapes.values()), "Retail geometry streaming count drifted")
    return result


def parse_fields(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for match in FIELD_RE.finditer(text):
        fields[match.group(1)] = match.group(2) if match.group(2) is not None else match.group(3)
    return fields


def int_field(fields: dict[str, str], key: str, default: int = 0) -> int:
    value = fields.get(key)
    if value is None:
        return default
    try:
        return int(value, 0)
    except ValueError:
        return default


def normalized_alias(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.lower())


def select_ledger_fields(fields: dict[str, str], line_number: int) -> dict[str, Any]:
    selected_keys = (
        "phase",
        "kind",
        "role",
        "index",
        "form",
        "editor",
        "model",
        "required",
        "coveredByEquipment",
        "attached",
        "renderable",
        "hiddenByProof",
        "drawState",
        "weaponDrawn",
        "status",
        "object",
        "visualNode",
        "visualRenderableGeometry",
        "bodyRequired",
        "bodyAttached",
        "bodyCovered",
        "bodyComplete",
        "raceFaceRequired",
        "raceFaceAttached",
        "raceFaceComplete",
        "npcHeadRequired",
        "npcHeadAttached",
        "npcHeadTotalWithExtras",
        "npcHeadComplete",
        "hairRequired",
        "hairComplete",
        "armorRequired",
        "armorAttached",
        "clothingRequired",
        "clothingAttached",
        "weaponRequired",
        "weaponAttached",
        "weaponHiddenByProof",
    )
    selected: dict[str, Any] = {key: fields[key] for key in selected_keys if key in fields}
    selected["line"] = line_number
    return selected


def parse_openmw_telemetry(
    log_path: Path, rows_by_capture: dict[str, dict[str, Any]]
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    expected_by_ref = {row["authoredRef"]: row for row in rows_by_capture.values()}
    base_to_refs: dict[str, set[str]] = defaultdict(set)
    for ref, row in expected_by_ref.items():
        base_to_refs[row["base"]].add(ref)

    working: dict[str, dict[str, Any]] = {
        ref: {
            "parts": {},
            "equipment": {},
            "assemblyGate": None,
            "renderInsertEnd": None,
            "partsEnd": None,
            "ledgerEventCount": 0,
            "aliases": set(),
            "matrix": {},
            "matrixObservations": 0,
            "matrixNonFinite": [],
        }
        for ref in expected_by_ref
    }
    alias_to_refs: dict[str, set[str]] = defaultdict(set)

    with log_path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            marker = "World viewer actor ledger:"
            marker_index = line.find(marker)
            if marker_index < 0:
                continue
            fields = parse_fields(line[marker_index + len(marker) :])
            raw_ref = fields.get("ref")
            if not raw_ref or is_synthetic_form(raw_ref):
                continue
            try:
                ref = canonical_form(raw_ref, f"OpenMW actor ledger line {line_number} ref")
            except ContractError:
                continue
            if ref not in expected_by_ref:
                continue
            raw_base = fields.get("base")
            if raw_base and FORM_RE.search(raw_base) and not is_synthetic_form(raw_base):
                base = canonical_form(raw_base, f"OpenMW actor ledger line {line_number} base")
                require(base == expected_by_ref[ref]["base"], f"OpenMW actor-ledger base mismatch for {ref} at line {line_number}")
            current = working[ref]
            current["ledgerEventCount"] += 1
            for alias_key in ("name", "npc", "editor"):
                alias = fields.get(alias_key)
                if alias:
                    normalized = normalized_alias(alias)
                    if normalized:
                        current["aliases"].add(alias)
                        alias_to_refs[normalized].add(ref)

            phase = fields.get("phase")
            selected = select_ledger_fields(fields, line_number)
            if phase == "actor-part-manifest":
                key = tuple(fields.get(name, "") for name in ("kind", "role", "index", "form", "editor", "model"))
                current["parts"][key] = selected
            elif phase == "equipment-part":
                key = tuple(fields.get(name, "") for name in ("kind", "form", "editor", "model"))
                current["equipment"][key] = selected
            elif phase == "actor-assembly-gate":
                current["assemblyGate"] = selected
            elif phase == "render-insert-end":
                current["renderInsertEnd"] = selected
            elif phase == "parts-end":
                current["partsEnd"] = selected

    unassigned_matrix_lines = 0
    current_ref: str | None = None
    with log_path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            ledger_marker = "World viewer actor ledger:"
            ledger_index = line.find(ledger_marker)
            if ledger_index >= 0:
                fields = parse_fields(line[ledger_index + len(ledger_marker) :])
                raw_ref = fields.get("ref")
                if raw_ref and not is_synthetic_form(raw_ref):
                    try:
                        candidate = canonical_form(raw_ref, f"OpenMW matrix context line {line_number}")
                    except ContractError:
                        candidate = ""
                    current_ref = candidate if candidate in expected_by_ref else None

            matrix_match = PART_MATRIX_RE.search(line)
            if not matrix_match:
                continue
            actor_token = matrix_match.group("actor").strip()
            candidates: set[str] = set()
            if FORM_RE.search(actor_token) and not is_synthetic_form(actor_token):
                token_form = canonical_form(actor_token, f"OpenMW part-matrix actor line {line_number}")
                if token_form in expected_by_ref:
                    candidates.add(token_form)
                candidates.update(base_to_refs.get(token_form, set()))
            else:
                actor_alias = actor_token.strip('"')
                candidates.update(alias_to_refs.get(normalized_alias(actor_alias), set()))
            selected_ref: str | None = None
            if len(candidates) == 1:
                selected_ref = next(iter(candidates))
            elif current_ref and current_ref in candidates:
                selected_ref = current_ref
            elif not candidates and current_ref:
                selected_ref = current_ref
            if selected_ref is None:
                # The viewer may also audit the player or other out-of-roster
                # scene actors. Count only ambiguous lines that resolve to more
                # than one canonical target; unrelated actors are not evidence.
                if candidates:
                    unassigned_matrix_lines += 1
                continue

            part = matrix_match.group("part")
            part_class = matrix_match.group("part_class")
            flags = {
                key: int(value)
                for key, value in re.findall(r"\b(finite\w+|partHandedness|anchorHandedness)=([01])(?:\b|$)", line)
            }
            matrix_item = {
                "line": line_number,
                "part": part,
                "class": part_class,
                "finite": flags,
            }
            current = working[selected_ref]
            current["matrix"][(part_class, part)] = matrix_item
            current["matrixObservations"] += 1
            if any(value == 0 for key, value in flags.items() if key.startswith("finite")):
                current["matrixNonFinite"].append(matrix_item)

    summaries: dict[str, dict[str, Any]] = {}
    for ref, current in working.items():
        parts = list(current["parts"].values())
        equipment = list(current["equipment"].values())
        matrices = list(current["matrix"].values())
        missing_parts = [
            item
            for item in parts
            if int_field(item, "required") == 1
            and int_field(item, "coveredByEquipment") != 1
            and (int_field(item, "attached") != 1 or int_field(item, "renderable") != 1)
        ]
        missing_equipment = [
            item
            for item in equipment
            if int_field(item, "required") == 1
            and (
                int_field(item, "attached") != 1
                or int_field(item, "renderable") != 1
                or int_field(item, "hiddenByProof") == 1
            )
        ]
        undrawn_required_weapons = [
            item
            for item in equipment
            if int_field(item, "required") == 1
            and str(item.get("kind") or "").casefold() == "weapon"
            and int_field(item, "weaponDrawn") != 1
        ]
        kind_counts = Counter(str(item.get("kind") or "unknown") for item in parts)
        role_counts = Counter(str(item.get("role") or "") for item in parts if item.get("role"))
        equipment_counts = Counter(str(item.get("kind") or "unknown") for item in equipment)
        matrix_counts = Counter(str(item.get("class") or "unknown") for item in matrices)
        semantic_texts: list[str] = []
        for item in parts + equipment:
            semantic_texts.extend(str(item.get(key) or "") for key in ("kind", "role", "editor", "model"))
        for item in matrices:
            semantic_texts.extend((str(item.get("class") or ""), str(item.get("part") or "")))
        assembly = current["assemblyGate"] or {}
        if int_field(assembly, "hairRequired") > 0 and int_field(assembly, "hairComplete") == 1:
            semantic_texts.append("hair assembly complete")
        if int_field(assembly, "bodyRequired") > 0 and int_field(assembly, "bodyComplete") == 1:
            semantic_texts.append("body assembly complete")
        if int_field(assembly, "armorRequired") > 0 or int_field(assembly, "clothingRequired") > 0:
            semantic_texts.append("armor clothing assembly")
        if int_field(assembly, "weaponRequired") > 0 and int_field(assembly, "weaponAttached") > 0:
            semantic_texts.append("weapon assembly attached")
        render_end = current["renderInsertEnd"] or {}
        if int_field(render_end, "object") == 1:
            semantic_texts.append("body render object")

        summaries[ref] = {
            "ledgerEventCount": int(current["ledgerEventCount"]),
            "aliases": sorted(current["aliases"], key=str.casefold),
            "partCount": len(parts),
            "requiredPartCount": sum(int_field(item, "required") == 1 for item in parts),
            "attachedPartCount": sum(int_field(item, "attached") == 1 for item in parts),
            "coveredPartCount": sum(int_field(item, "coveredByEquipment") == 1 for item in parts),
            "missingRequiredParts": missing_parts,
            "partKindCounts": dict(sorted(kind_counts.items())),
            "partRoleCounts": dict(sorted(role_counts.items())),
            "parts": parts,
            "equipmentCount": len(equipment),
            "requiredEquipmentCount": sum(int_field(item, "required") == 1 for item in equipment),
            "attachedEquipmentCount": sum(int_field(item, "attached") == 1 for item in equipment),
            "missingRequiredEquipment": missing_equipment,
            "undrawnRequiredWeapons": undrawn_required_weapons,
            "equipmentKindCounts": dict(sorted(equipment_counts.items())),
            "equipment": equipment,
            "assemblyGate": current["assemblyGate"],
            "renderInsertEnd": current["renderInsertEnd"],
            "partsEnd": current["partsEnd"],
            "partMatrix": {
                "observationCount": int(current["matrixObservations"]),
                "uniqueCount": len(matrices),
                "classCounts": dict(sorted(matrix_counts.items())),
                "parts": matrices,
                "nonFinite": current["matrixNonFinite"],
            },
            "semantics": semantic_flags(semantic_texts),
        }

    return summaries, {"unassignedPartMatrixLines": unassigned_matrix_lines}


def telemetry_gate(
    category: str, retail_geometry: dict[str, Any], openmw: dict[str, Any]
) -> dict[str, Any]:
    failures: list[str] = []
    humanoid = "humanoid" in category.lower()
    if openmw["ledgerEventCount"] == 0:
        failures.append("missing-actor-ledger")
    if openmw["missingRequiredParts"]:
        failures.append("missing-required-parts")
    if openmw["missingRequiredEquipment"]:
        failures.append("missing-required-equipment")
    if openmw["undrawnRequiredWeapons"]:
        failures.append("required-weapon-not-drawn")
    if openmw["partMatrix"]["nonFinite"]:
        failures.append("nonfinite-part-matrix")

    assembly = openmw.get("assemblyGate")
    render_end = openmw.get("renderInsertEnd")
    if humanoid:
        if not assembly:
            failures.append("missing-assembly-gate")
        elif assembly.get("status") != "passed":
            failures.append("assembly-gate-failed")
        if not openmw.get("partsEnd"):
            failures.append("missing-parts-end")
    elif not render_end or int_field(render_end, "object") != 1:
        failures.append("render-insert-incomplete")

    retail_semantics = retail_geometry["semantics"]
    openmw_semantics = openmw["semantics"]
    missing_semantics = [
        key for key in SEMANTIC_KEYS if retail_semantics.get(key) and not openmw_semantics.get(key)
    ]
    failures.extend(f"missing-semantic-{key}" for key in missing_semantics)
    failures = list(dict.fromkeys(failures))
    return {
        "status": "passed" if not failures else "failed",
        "failures": failures,
        "retailRequiredSemantics": [key for key in SEMANTIC_KEYS if retail_semantics.get(key)],
        "openmwPresentSemantics": [key for key in SEMANTIC_KEYS if openmw_semantics.get(key)],
        "missingSemantics": missing_semantics,
    }


def font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    name = "arialbd.ttf" if bold else "arial.ttf"
    path = Path("C:/Windows/Fonts") / name
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    image = image.convert("RGB")
    image.thumbnail(size, Image.Resampling.LANCZOS)
    output = Image.new("RGB", size, (12, 12, 12))
    output.paste(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return output


def clipped_text(value: str, limit: int) -> str:
    return value if len(value) <= limit else value[: limit - 1] + "…"


def build_sheet(rows: list[dict[str, Any]], output: Path) -> None:
    image_size = (250, 250)
    gap = 12
    card_width = image_size[0] * 2 + gap + 18
    card_height = 352
    cards_per_row = 3
    card_rows = (len(rows) + cards_per_row - 1) // cards_per_row
    margin = 18
    title_height = 72
    canvas = Image.new(
        "RGB",
        (margin * 2 + card_width * cards_per_row, margin * 2 + title_height + card_height * card_rows),
        (18, 18, 18),
    )
    draw = ImageDraw.Draw(canvas)
    draw.text((margin, margin), "GOODSPRINGS — STRICT CAPTURE-ID COMPARISON", font=font(27, True), fill=(245, 245, 245))
    draw.text(
        (margin, margin + 35),
        "Retail telemetry (left)  |  OpenMW native capture (right)  |  keyed join only",
        font=font(16),
        fill=(185, 185, 185),
    )

    for index, row in enumerate(rows):
        column = index % cards_per_row
        row_number = index // cards_per_row
        x = margin + column * card_width
        y = margin + title_height + row_number * card_height
        passed = row["gates"]["status"] == "passed"
        border = (55, 170, 90) if passed else (210, 70, 65)
        draw.rectangle((x, y, x + card_width - 4, y + card_height - 4), outline=border, width=3)
        draw.text(
            (x + 8, y + 7),
            clipped_text(f"{index + 1:02d}  {row['captureId']}", 57),
            font=font(16, True),
            fill=(245, 245, 245),
        )
        image_y = y + 34
        with Image.open(row["retail"]["screenshot"]["path"]) as retail_source:
            retail = fit(retail_source, image_size)
        with Image.open(row["openmw"]["screenshot"]["path"]) as openmw_source:
            openmw = fit(openmw_source, image_size)
        canvas.paste(retail, (x + 6, image_y))
        canvas.paste(openmw, (x + 6 + image_size[0] + gap, image_y))
        draw.text((x + 8, image_y + image_size[1] + 3), "RETAIL", font=font(13, True), fill=(110, 190, 255))
        draw.text(
            (x + 8 + image_size[0] + gap, image_y + image_size[1] + 3),
            "OPENMW",
            font=font(13, True),
            fill=(255, 185, 90),
        )
        telemetry = row["openmw"]["actorTelemetry"]
        summary = (
            f"retail geom {row['retail']['geometry']['shapeCount']}  |  "
            f"OpenMW parts {telemetry['partCount']} eq {telemetry['equipmentCount']} "
            f"matrix {telemetry['partMatrix']['uniqueCount']}"
        )
        draw.text((x + 8, image_y + image_size[1] + 23), clipped_text(summary, 78), font=font(12), fill=(205, 205, 205))
        gate_text = "GATES PASS" if passed else "FAIL: " + ", ".join(row["gates"]["failures"])
        draw.text((x + 8, image_y + image_size[1] + 41), clipped_text(gate_text, 82), font=font(12, True), fill=border)

    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG", optimize=True)


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def build_comparison(args: argparse.Namespace) -> tuple[dict[str, Any], Path, Path]:
    retail_manifest_path = Path(args.retail_manifest).resolve()
    openmw_index_path = Path(args.openmw_batch_index).resolve()
    output_sheet = Path(args.output_sheet).resolve()
    output_manifest = (
        Path(args.output_manifest).resolve()
        if args.output_manifest
        else output_sheet.with_name(output_sheet.stem + ".manifest.json")
    )
    require(output_sheet != output_manifest, "Output sheet and comparison manifest paths must differ")

    retail, retail_order, jsonl_path = validate_retail_manifest(retail_manifest_path)
    roster_hash = str(retail.get("canonicalRosterSha256") or "") or None
    openmw, openmw_capture_manifest_path, openmw_log_path = validate_openmw_manifest(
        openmw_index_path, roster_hash
    )
    retail_rows = retail["_normalizedRows"]
    openmw_rows = openmw["_normalizedRows"]
    retail_capture_ids = set(retail_rows)
    openmw_capture_ids = set(openmw_rows)
    require(
        retail_capture_ids == openmw_capture_ids,
        "captureId sets differ; refusing order-based fallback. "
        f"Missing in OpenMW={sorted(retail_capture_ids - openmw_capture_ids)}; "
        f"missing in retail={sorted(openmw_capture_ids - retail_capture_ids)}",
    )
    require(len(retail_capture_ids) == EXPECTED_CAPTURE_COUNT, "Joined captureId count is not exactly 37")

    for capture_id in retail_order:
        retail_row = retail_rows[capture_id]
        openmw_row = openmw_rows[capture_id]
        for field in ("targetId", "category", "authoredRef", "base", "shotKind"):
            require(
                retail_row[field] == openmw_row[field],
                f"Retail/OpenMW {field} mismatch for captureId {capture_id}: "
                f"{retail_row[field]!r} != {openmw_row[field]!r}",
            )

    retail_geometry = parse_retail_geometry(jsonl_path, retail_rows)
    openmw_telemetry, telemetry_summary = parse_openmw_telemetry(openmw_log_path, openmw_rows)
    require(
        telemetry_summary["unassignedPartMatrixLines"] == 0,
        "OpenMW part-matrix telemetry is ambiguous across canonical targets",
    )

    comparison_rows: list[dict[str, Any]] = []
    for capture_id in retail_order:
        retail_row = retail_rows[capture_id]
        openmw_row = openmw_rows[capture_id]
        geometry = retail_geometry[retail_row["authoredRef"]]
        telemetry = openmw_telemetry[openmw_row["authoredRef"]]
        gates = telemetry_gate(retail_row["category"], geometry, telemetry)
        comparison_rows.append(
            {
                "captureId": capture_id,
                "targetId": retail_row["targetId"],
                "category": retail_row["category"],
                "authoredRef": retail_row["authoredRef"],
                "base": retail_row["base"],
                "shotKind": retail_row["shotKind"],
                "retail": {
                    "screenshot": evidence(retail_row["screenshot"], "retail-screenshot"),
                    "geometry": geometry,
                },
                "openmw": {
                    "screenshot": evidence(openmw_row["screenshot"], "openmw-native-screenshot-copy"),
                    "requestedFrame": openmw_row["requestedFrame"],
                    "actualFrame": openmw_row["actualFrame"],
                    "frameDrift": openmw_row["frameDrift"],
                    "actorTelemetry": telemetry,
                },
                "gates": gates,
            }
        )

    build_sheet(comparison_rows, output_sheet)
    failed_rows = [row for row in comparison_rows if row["gates"]["status"] != "passed"]
    result: dict[str, Any] = {
        "schema": OUTPUT_SCHEMA,
        "status": "passed" if not failed_rows else "failed",
        "pairing": {
            "key": "captureId",
            "fallbackPairing": False,
            "expectedCount": EXPECTED_CAPTURE_COUNT,
            "pairedCount": len(comparison_rows),
            "presentationOrder": "canonical-retail-manifest-order-after-captureId-join",
        },
        "inputs": {
            "retailManifest": evidence(retail_manifest_path, "retail-full-telemetry-manifest"),
            "retailJsonl": evidence(jsonl_path, "retail-oracle-jsonl"),
            "openmwBatchIndex": evidence(openmw_index_path, "openmw-actor-batch-index"),
            "openmwCaptureManifest": evidence(openmw_capture_manifest_path, "openmw-capture-manifest"),
            "openmwLog": evidence(openmw_log_path, "openmw-telemetry-log"),
            "canonicalRosterSha256": roster_hash,
        },
        "outputs": {
            "sheet": evidence(output_sheet, "goodsprings-side-by-side-sheet"),
            "manifest": str(output_manifest),
        },
        "summary": {
            "passed": len(comparison_rows) - len(failed_rows),
            "failed": len(failed_rows),
            "failedCaptureIds": [row["captureId"] for row in failed_rows],
            "retailGeometryShapeCount": sum(row["retail"]["geometry"]["shapeCount"] for row in comparison_rows),
            "openmwPartCount": sum(row["openmw"]["actorTelemetry"]["partCount"] for row in comparison_rows),
            "openmwEquipmentCount": sum(
                row["openmw"]["actorTelemetry"]["equipmentCount"] for row in comparison_rows
            ),
            "openmwPartMatrixCount": sum(
                row["openmw"]["actorTelemetry"]["partMatrix"]["uniqueCount"] for row in comparison_rows
            ),
            **telemetry_summary,
        },
        "rows": comparison_rows,
    }
    write_json_atomic(output_manifest, result)
    return result, output_sheet, output_manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Strictly join 37 retail/OpenMW Goodsprings captures by captureId and audit actor parts."
    )
    parser.add_argument("--retail-manifest", required=True, help="Canonical retail full-telemetry-manifest.json")
    parser.add_argument("--openmw-batch-index", required=True, help="OpenMW one-process batch-index.json")
    parser.add_argument("--output-sheet", required=True, help="Output side-by-side PNG")
    parser.add_argument("--output-manifest", help="Output comparison JSON (defaults beside the sheet)")
    return parser.parse_args()


def main() -> int:
    try:
        result, sheet, manifest = build_comparison(parse_args())
    except ContractError as exc:
        print(f"comparison contract failed: {exc}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "status": result["status"],
                "paired": result["pairing"]["pairedCount"],
                "failed": result["summary"]["failed"],
                "sheet": str(sheet),
                "manifest": str(manifest),
            },
            indent=2,
        )
    )
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
