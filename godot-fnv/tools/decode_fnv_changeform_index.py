#!/usr/bin/env python3
"""Build a lossless, fail-closed index of Fallout: New Vegas save change forms.

This deliberately does not interpret the variable change-form payloads.  It proves
the container boundaries, resolves save RefIDs, and retains the byte-exact payload
region so later semantic decoders can be added without silently inventing state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MAGIC = b"FO3SAVEGAME"
PIPE = 0x7C
FLT_SIZE = 0x6E
TYPE_NAMES = [
    "REFR", "ACHR", "ACRE", "PMIS", "PGRE", "PBEA", "PFLA", "CELL",
    "INFO", "QUST", "NPC_", "CREA", "ACTI", "TACT", "TERM", "ARMO",
    "BOOK", "CLOT", "CONT", "DOOR", "INGR", "LIGH", "MISC", "STAT",
    "MSTT", "FURN", "WEAP", "AMMO", "KEYM", "ALCH", "IDLM", "NOTE",
    "ECZN", "CLAS", "FACT", "PACK", "NAVM", "FLST", "LVLC", "LVLN",
    "LVLI", "WATR", "IMOD", "REPU", "PCBE", "RCPE", "RCCT", "CHIP",
    "CSNO", "LSCT", "CHAL", "AMEF", "CCRD", "CMNY", "CDCK",
]
REFID_KINDS = ("formIdArray", "default", "created", "unknown")


class DecodeError(RuntimeError):
    pass


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DecodeError(message)


def read_u32t(data: bytes, pos: int) -> tuple[int, int]:
    require(pos + 5 <= len(data), "truncated pipe-terminated uint32")
    value = u32(data, pos)
    require(data[pos + 4] == PIPE, "missing uint32 pipe terminator")
    return value, pos + 5


def read_master_table(data: bytes, pos: int, size: int) -> tuple[list[str], int]:
    end = pos + size
    require(size > 0 and end <= len(data), "invalid master table extent")
    require(pos + 2 <= end, "truncated master table")
    count = data[pos]
    pos += 1
    require(data[pos] == PIPE, "missing master-count terminator")
    pos += 1
    masters: list[str] = []
    for index in range(count):
        require(pos + 3 <= end, f"truncated master name length at {index}")
        length = u16(data, pos)
        pos += 2
        require(data[pos] == PIPE, f"missing master length terminator at {index}")
        pos += 1
        require(pos + length <= end, f"truncated master name at {index}")
        raw = data[pos : pos + length]
        pos += length
        if length:
            require(pos < end and data[pos] == PIPE, f"missing master name terminator at {index}")
            pos += 1
        try:
            masters.append(raw.decode("ascii"))
        except UnicodeDecodeError as exc:
            raise DecodeError(f"non-ASCII master name at {index}") from exc
    require(pos == end, f"master table has {end - pos} unaccounted bytes")
    return masters, end


def locate_file_table(data: bytes) -> tuple[dict[str, Any], int]:
    require(data.startswith(MAGIC), "not a raw FO3SAVEGAME save")
    require(len(data) >= 20, "truncated save header")
    header_size = u32(data, len(MAGIC))
    header_start = len(MAGIC) + 4
    header_end = header_start + header_size
    require(header_size > 0 and header_end <= len(data), "invalid save header size")

    pos = header_start
    _version, pos = read_u32t(data, pos)
    dimension_or_language = u32(data, pos)
    if dimension_or_language > 16384:
        require(pos + 65 <= header_end, "truncated 64-byte language field")
        pos += 64
        require(data[pos] == PIPE, "missing language terminator")
        pos += 1
    width, pos = read_u32t(data, pos)
    height, _ = read_u32t(data, pos)
    require(0 < width <= 16384 and 0 < height <= 16384, "invalid screenshot dimensions")

    screenshot_bytes = width * height * 3
    form_version_pos = header_end + screenshot_bytes
    require(form_version_pos + 5 <= len(data), "truncated screenshot/master header")
    form_version = data[form_version_pos]
    master_table_size = u32(data, form_version_pos + 1)
    masters, flt_pos = read_master_table(data, form_version_pos + 5, master_table_size)
    require(flt_pos + FLT_SIZE <= len(data), "truncated file location table")
    fields = struct.unpack_from("<9I", data, flt_pos)
    flt = {
        "refIdArrayOffset": fields[0],
        "unknownTableOffset": fields[1],
        "globalData1Offset": fields[2],
        "changedFormsOffset": fields[3],
        "globalData2Offset": fields[4],
        "globalData1Count": fields[5],
        "globalData2Count": fields[6],
        "changedFormsCount": fields[7],
        "unknownCount": fields[8],
    }
    require(flt_pos < flt["globalData1Offset"] <= flt["changedFormsOffset"], "invalid early section offsets")
    require(flt["changedFormsOffset"] <= flt["globalData2Offset"] <= flt["refIdArrayOffset"], "invalid late section offsets")
    require(flt["refIdArrayOffset"] < len(data), "RefID array offset is outside save")
    header = {
        "headerSize": header_size,
        "screenshotWidth": width,
        "screenshotHeight": height,
        "formVersion": form_version,
        "masters": masters,
        "fileLocationTableOffset": flt_pos,
        "fileLocationTable": flt,
    }
    return header, flt_pos


def parse_form_id_array(data: bytes, offset: int) -> tuple[list[int], int]:
    require(offset + 4 <= len(data), "truncated FormID array count")
    count = u32(data, offset)
    require(count <= 1_000_000, f"implausible FormID array count {count}")
    end = offset + 4 + count * 4
    require(end <= len(data), "truncated FormID array")
    return list(struct.unpack_from(f"<{count}I", data, offset + 4)) if count else [], end


def decode_refid(raw: int, form_ids: list[int]) -> dict[str, Any]:
    kind_code = raw >> 22
    value = raw & 0x3FFFFF
    resolved: int | None
    if kind_code == 0:
        resolved = form_ids[value - 1] if value and value <= len(form_ids) else None
    elif kind_code == 1:
        resolved = value
    elif kind_code == 2:
        resolved = 0xFF000000 | value
    else:
        resolved = None
    return {
        "raw": f"0x{raw:06x}",
        "kind": REFID_KINDS[kind_code],
        "value": value,
        "resolvedFormId": f"0x{resolved:08x}" if resolved is not None else None,
    }


def read_refid(data: bytes, offset: int, form_ids: list[int]) -> dict[str, Any]:
    require(offset + 3 <= len(data), "truncated payload RefID")
    return decode_refid(int.from_bytes(data[offset : offset + 3], "big"), form_ids)


def decode_initial_state(form: "RawChangeForm", form_ids: list[int]) -> dict[str, Any] | None:
    """Decode only the fixed initial-data prefix defined by the FNV save grammar."""
    if form.change_type not in (0, 1, 2, 3, 4, 5, 6, 44):
        return None
    created = (form.refid >> 22) == 2
    cell_changed = bool(form.flags & (1 << 3))
    moved = bool(form.flags & (1 << 1))
    payload = form.payload
    if created:
        require(len(payload) >= 31, "created reference has a truncated initial-data prefix")
        values = struct.unpack_from("<6f", payload, 3)
        return {
            "kind": "created",
            "bytes": 31,
            "cellOrWorldspace": read_refid(payload, 0, form_ids),
            "position": list(values[:3]),
            "rotationRadians": list(values[3:]),
            "flags": payload[27],
            "baseForm": read_refid(payload, 28, form_ids),
        }
    if cell_changed:
        require(len(payload) >= 34, "cell-changed reference has a truncated initial-data prefix")
        values = struct.unpack_from("<6f", payload, 3)
        coord_x, coord_y = struct.unpack_from("<hh", payload, 30)
        return {
            "kind": "cellChanged",
            "bytes": 34,
            "oldCellOrWorldspace": read_refid(payload, 0, form_ids),
            "position": list(values[:3]),
            "rotationRadians": list(values[3:]),
            "newCellOrWorldspace": read_refid(payload, 27, form_ids),
            "newCellGrid": [coord_x, coord_y],
        }
    if moved:
        require(len(payload) >= 27, "moved reference has a truncated initial-data prefix")
        values = struct.unpack_from("<6f", payload, 3)
        return {
            "kind": "moved",
            "bytes": 27,
            "cellOrWorldspace": read_refid(payload, 0, form_ids),
            "position": list(values[:3]),
            "rotationRadians": list(values[3:]),
        }
    return None


@dataclass(frozen=True)
class RawChangeForm:
    refid: int
    flags: int
    change_type: int
    length_code: int
    version: int
    record_offset: int
    payload_offset: int
    payload: bytes


def parse_changed_forms(data: bytes, offset: int, count: int, expected_end: int | None = None) -> tuple[list[RawChangeForm], int]:
    forms: list[RawChangeForm] = []
    pos = offset
    for index in range(count):
        record_offset = pos
        require(pos + 10 <= len(data), f"truncated change-form header at index {index}")
        refid = int.from_bytes(data[pos : pos + 3], "big")
        pos += 3
        flags = u32(data, pos)
        pos += 4
        raw_type = data[pos]
        pos += 1
        version = data[pos]
        pos += 1
        change_type = raw_type & 0x3F
        length_code = raw_type >> 6
        require(length_code != 3, f"invalid change-form length code at index {index}")
        width = (1, 2, 4)[length_code]
        require(pos + width <= len(data), f"truncated change-form length at index {index}")
        length = int.from_bytes(data[pos : pos + width], "little")
        pos += width
        payload_offset = pos
        require(pos + length <= len(data), f"truncated change-form payload at index {index}")
        payload = data[pos : pos + length]
        pos += length
        forms.append(RawChangeForm(refid, flags, change_type, length_code, version, record_offset, payload_offset, payload))
    if expected_end is not None:
        require(pos == expected_end, f"change-form table ended at 0x{pos:x}, expected 0x{expected_end:x}")
    return forms, pos


def load_semantic_placements(semantic_dir: Path | None) -> tuple[dict[int, dict[str, Any]], dict[str, Any] | None]:
    if semantic_dir is None:
        return {}, None
    manifest_path = semantic_dir / "manifest.json"
    require(manifest_path.is_file(), f"missing semantic manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    placements: dict[int, dict[str, Any]] = {}
    shard_paths = sorted((semantic_dir / "placements").glob("*.json"))
    require(len(shard_paths) == 256, f"expected 256 semantic placement shards, found {len(shard_paths)}")
    for shard_path in shard_paths:
        shard = json.loads(shard_path.read_text(encoding="utf-8"))
        for row in shard.get("placements", []):
            form_id = int(row["id"], 16)
            require(form_id not in placements, f"duplicate semantic placement {row['id']}")
            placements[form_id] = {
                "type": row.get("type"),
                "base": row.get("base"),
                "baseType": row.get("baseType"),
                "parentCell": row.get("parentCell"),
                "sourcePlugin": row.get("sourcePlugin"),
            }
    expected = int(manifest.get("counts", {}).get("placements", -1))
    require(len(placements) == expected, f"semantic placement denominator mismatch: {len(placements)} != {expected}")
    return placements, {"path": str(manifest_path.resolve()), "sha256": sha256(manifest_path.read_bytes())}


def build_index(save_path: Path, output_dir: Path, semantic_dir: Path | None = None) -> dict[str, Any]:
    data = save_path.read_bytes()
    header, _ = locate_file_table(data)
    flt = header["fileLocationTable"]
    form_ids, after_form_ids = parse_form_id_array(data, flt["refIdArrayOffset"])
    visited, after_visited = parse_form_id_array(data, after_form_ids)
    forms, table_end = parse_changed_forms(
        data, flt["changedFormsOffset"], flt["changedFormsCount"], flt["globalData2Offset"]
    )
    table_blob = data[flt["changedFormsOffset"] : table_end]
    payload_blob = b"".join(form.payload for form in forms)
    type_counts = Counter(TYPE_NAMES[f.change_type] if f.change_type < len(TYPE_NAMES) else f"UNKNOWN_{f.change_type}" for f in forms)
    kind_counts = Counter(REFID_KINDS[f.refid >> 22] for f in forms)
    semantic_placements, semantic_source = load_semantic_placements(semantic_dir)
    entries = []
    payload_cursor = 0
    unresolved = 0
    semantic_matches = Counter()
    initial_state_counts = Counter()
    for index, form in enumerate(forms):
        ref = decode_refid(form.refid, form_ids)
        unresolved += ref["resolvedFormId"] is None
        resolved_number = int(ref["resolvedFormId"], 16) if ref["resolvedFormId"] is not None else None
        semantic = semantic_placements.get(resolved_number) if resolved_number is not None else None
        initial_state = decode_initial_state(form, form_ids)
        if initial_state is not None:
            initial_state_counts[initial_state["kind"]] += 1
        semantic_matches["matched" if semantic is not None else "unmatched"] += 1
        if semantic is not None:
            semantic_matches[f"matched_{semantic.get('type', 'unknown')}"] += 1
        entries.append({
            "index": index,
            "refId": ref,
            "changeFlags": f"0x{form.flags:08x}",
            "changeType": form.change_type,
            "type": TYPE_NAMES[form.change_type] if form.change_type < len(TYPE_NAMES) else "UNKNOWN",
            "lengthCode": form.length_code,
            "version": form.version,
            "recordOffset": form.record_offset,
            "sourcePayloadOffset": form.payload_offset,
            "payloadOffset": payload_cursor,
            "payloadBytes": len(form.payload),
            "payloadSha256": sha256(form.payload),
            "semanticCoverage": "initial-state" if initial_state is not None else "opaque",
            "initialState": initial_state,
            "authoredPlacement": semantic,
        })
        payload_cursor += len(form.payload)

    output_dir.mkdir(parents=True, exist_ok=True)
    payload_path = output_dir / "changeform-payloads.bin"
    payload_path.write_bytes(payload_blob)
    index = {
        "schema": "opennv-fos-changeform-index/v1",
        "status": "indexed-opaque",
        "source": {"path": str(save_path.resolve()), "bytes": len(data), "sha256": sha256(data)},
        "header": header,
        "counts": {
            "changeForms": len(forms),
            "formIds": len(form_ids),
            "visitedWorldspaces": len(visited),
            "unresolvedRefIds": unresolved,
            "changeFormTableBytes": len(table_blob),
            "payloadBytes": len(payload_blob),
            "byType": dict(sorted(type_counts.items())),
            "byRefIdKind": dict(sorted(kind_counts.items())),
            "semanticPlacementJoin": dict(sorted(semantic_matches.items())),
            "decodedInitialState": dict(sorted(initial_state_counts.items())),
        },
        "integrity": {
            "declaredChangeForms": flt["changedFormsCount"],
            "tableStart": flt["changedFormsOffset"],
            "tableEnd": table_end,
            "expectedTableEnd": flt["globalData2Offset"],
            "tableSha256": sha256(table_blob),
            "payloadArtifact": {
                "path": payload_path.name,
                "bytes": len(payload_blob),
                "sha256": sha256(payload_blob),
            },
            "afterVisitedWorldspacesOffset": after_visited,
        },
        "coverage": {
            "containerBoundaries": "complete",
            "refIdResolution": "complete" if unresolved == 0 else "partial",
            "payloadRetention": "complete",
            "payloadSemantics": "opaque",
            "note": "No world-state field is promoted until its type/flag payload decoder is independently validated.",
        },
        "semanticDatabase": semantic_source,
        "formIds": [f"0x{value:08x}" for value in form_ids],
        "visitedWorldspaces": [f"0x{value:08x}" for value in visited],
        "changeForms": entries,
    }
    index_path = output_dir / "index.json"
    index_path.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    return index


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--save", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--semantic-db", type=Path)
    args = parser.parse_args()
    index = build_index(args.save, args.output_dir, args.semantic_db)
    print(json.dumps({"status": index["status"], **index["counts"]}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
