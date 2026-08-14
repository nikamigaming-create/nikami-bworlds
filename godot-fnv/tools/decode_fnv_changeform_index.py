#!/usr/bin/env python3
"""Build a lossless, fail-closed index of Fallout: New Vegas save change forms.

This proves container boundaries and retains every byte. It additionally promotes
the fixed initial reference prefix and an ExtraScript event list when its ordered
pipe-terminated FNV layouts can be consumed exactly; all later extras stay opaque.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
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


def read_terminated(data: bytes, pos: int, size: int, field: str) -> tuple[bytes, int]:
    require(pos + size < len(data), f"truncated {field}")
    require(data[pos + size] == PIPE, f"missing {field} pipe terminator")
    return data[pos : pos + size], pos + size + 1


def read_counter_terminated(data: bytes, pos: int, field: str) -> tuple[int, int]:
    require(pos < len(data), f"truncated {field} counter")
    width = {0: 1, 1: 2, 2: 4}.get(data[pos] & 3)
    require(width is not None, f"invalid {field} counter width")
    raw, pos = read_terminated(data, pos, width, field)
    value = int.from_bytes(raw, "little") >> 2
    require(width != 2 or value > 63, f"noncanonical {field} two-byte counter")
    require(width != 4 or value > 16383, f"noncanonical {field} four-byte counter")
    return value, pos


def decode_script_event_list(
    payload: bytes, pos: int, form_ids: list[int], version: int
) -> tuple[dict[str, Any], int]:
    variable_count, pos = read_counter_terminated(payload, pos, "script variables")
    variables = []
    variable_ids = set()
    for _ in range(variable_count):
        flag_raw, pos = read_terminated(payload, pos, 4, "script variable ID")
        flag_and_id = int.from_bytes(flag_raw, "little")
        variable_id = flag_and_id & 0x7FFFFFFF
        require(variable_id > 0, "zero script variable ID")
        require(variable_id not in variable_ids, "duplicate script variable ID")
        variable_ids.add(variable_id)
        variable = {"index": variable_id, "flagAndVarId": f"0x{flag_and_id:08x}"}
        if flag_and_id & 0x80000000:
            ref_raw, pos = read_terminated(payload, pos, 3, "script reference variable")
            variable.update(kind="reference", value=decode_refid(int.from_bytes(ref_raw, "big"), form_ids))
        else:
            value_raw, pos = read_terminated(payload, pos, 8, "script numeric variable")
            value = struct.unpack("<d", value_raw)[0]
            require(math.isfinite(value), "non-finite script numeric variable")
            variable.update(kind="numeric", value=value)
        variables.append(variable)
    has_struct_raw, pos = read_terminated(payload, pos, 1, "script event-list struct flag")
    has_struct = has_struct_raw[0] != 0
    if has_struct:
        _, pos = read_terminated(payload, pos, 8, "script event-list struct")
    on_load = None
    if version >= 21:
        on_load_raw, pos = read_terminated(payload, pos, 1, "script OnLoad flag")
        on_load = on_load_raw[0]
    return {
        "variables": variables,
        "hasStruct010": has_struct,
        "onLoad": on_load,
    }, pos


def decode_initial_state(form: "RawChangeForm", form_ids: list[int]) -> dict[str, Any] | None:
    """Decode only the fixed initial-data prefix defined by the FNV save grammar."""
    if form.change_type not in (0, 1, 2, 3, 4, 5, 6, 44):
        return None
    created = (form.refid >> 22) == 2
    cell_changed = bool(form.flags & (1 << 3))
    moved = bool(form.flags & ((1 << 1) | (1 << 2)))
    payload = form.payload
    def consume_havok(pos: int) -> tuple[int, int]:
        if not form.flags & (1 << 2):
            return pos, 0
        length, pos = read_counter_terminated(payload, pos, "havok-move")
        require(pos + length <= len(payload), "truncated havok-move payload")
        return pos + length, length
    if created:
        require(len(payload) >= 32 and payload[31] == PIPE, "created reference has a truncated initial-data prefix")
        values = struct.unpack_from("<6f", payload, 3)
        require(all(math.isfinite(value) for value in values), "non-finite created reference transform")
        consumed, havok_bytes = consume_havok(32)
        return {
            "kind": "created",
            "bytes": consumed,
            "havokBytes": havok_bytes,
            "cellOrWorldspace": read_refid(payload, 0, form_ids),
            "position": list(values[:3]),
            "rotationRadians": list(values[3:]),
            "flags": payload[27],
            "baseForm": read_refid(payload, 28, form_ids),
        }
    if cell_changed:
        require(len(payload) >= 35 and payload[34] == PIPE, "cell-changed reference has a truncated initial-data prefix")
        values = struct.unpack_from("<6f", payload, 3)
        require(all(math.isfinite(value) for value in values), "non-finite cell-changed reference transform")
        coord_x, coord_y = struct.unpack_from("<hh", payload, 30)
        consumed, havok_bytes = consume_havok(35)
        return {
            "kind": "cellChanged",
            "bytes": consumed,
            "havokBytes": havok_bytes,
            "oldCellOrWorldspace": read_refid(payload, 0, form_ids),
            "position": list(values[:3]),
            "rotationRadians": list(values[3:]),
            "newCellOrWorldspace": read_refid(payload, 27, form_ids),
            "newCellGrid": [coord_x, coord_y],
        }
    if moved:
        require(len(payload) >= 28 and payload[27] == PIPE, "moved reference has a truncated initial-data prefix")
        values = struct.unpack_from("<6f", payload, 3)
        require(all(math.isfinite(value) for value in values), "non-finite moved reference transform")
        consumed, havok_bytes = consume_havok(28)
        return {
            "kind": "moved",
            "bytes": consumed,
            "havokBytes": havok_bytes,
            "cellOrWorldspace": read_refid(payload, 0, form_ids),
            "position": list(values[:3]),
            "rotationRadians": list(values[3:]),
        }
    return None


def decode_leading_script_state(
    form: "RawChangeForm", form_ids: list[int], initial_state: dict[str, Any] | None
) -> dict[str, Any] | None:
    if form.change_type not in (0, 1, 2):
        return None
    if form.change_type in (1, 2) and decode_refid(form.refid, form_ids).get("resolvedFormId") == "0x00000014":
        return None  # Player ACHR has a large player-specific prefix before ChangedREFR.
    mask = 0xA4061840 if form.change_type in (1, 2) else 0xA4021C40
    if not form.flags & mask:
        return None
    payload = form.payload
    pos = int((initial_state or {}).get("bytes", 0))
    if form.change_type in (1, 2):
        _, pos = read_terminated(payload, pos, 1, "actor process level")
    if form.flags & 1:
        _, pos = read_terminated(payload, pos, 4, "reference flags")
    if form.flags & (1 << 4):
        _, pos = read_terminated(payload, pos, 4, "reference scale")
    extra_count, pos = read_counter_terminated(payload, pos, "changed-extra")
    if extra_count == 0:
        return None
    extra_type_raw, pos = read_terminated(payload, pos, 1, "extra type")
    if extra_type_raw[0] != 0x0D:  # FNV ExtraScript type.
        return None
    script_raw, pos = read_terminated(payload, pos, 3, "script RefID")
    script = decode_refid(int.from_bytes(script_raw, "big"), form_ids)
    event_list, pos = decode_script_event_list(payload, pos, form_ids, form.version)
    return {
        "coverage": "leading-extra-only",
        "extraCount": extra_count,
        "script": script,
        **event_list,
        "bytesThroughScript": pos,
    }


def decode_quest_state(form: "RawChangeForm", form_ids: list[int]) -> dict[str, Any] | None:
    """Decode the complete FNV QUST change-form grammar, failing on trailing bytes."""
    if form.change_type != 9:
        return None
    payload, pos = form.payload, 0
    result: dict[str, Any] = {"flags": None, "scriptDelay": None, "stages": [], "objectives": [], "scriptState": None}
    if form.flags & 1:
        raw, pos = read_terminated(payload, pos, 4, "quest form flags")
        result["formFlags"] = f"0x{int.from_bytes(raw, 'little'):08x}"
    if form.flags & (1 << 1):
        raw, pos = read_terminated(payload, pos, 1, "quest flags")
        result["flags"] = raw[0]
    if form.flags & (1 << 2):
        raw, pos = read_terminated(payload, pos, 4, "quest script delay")
        delay = struct.unpack("<f", raw)[0]
        require(math.isfinite(delay), "non-finite quest script delay")
        result["scriptDelay"] = delay
    if form.flags & (1 << 31):
        stage_count, pos = read_counter_terminated(payload, pos, "quest stages")
        stage_ids = set()
        for _ in range(stage_count):
            stage_raw, pos = read_terminated(payload, pos, 1, "quest stage ID")
            status_raw, pos = read_terminated(payload, pos, 1, "quest stage status")
            stage_id = stage_raw[0]
            require(stage_id not in stage_ids, "duplicate quest stage ID")
            stage_ids.add(stage_id)
            log_count, pos = read_counter_terminated(payload, pos, "quest stage log entries")
            logs = []
            log_ids = set()
            for _ in range(log_count):
                log_raw, pos = read_terminated(payload, pos, 1, "quest log entry ID")
                has_data_raw, pos = read_terminated(payload, pos, 1, "quest log data flag")
                log_id = log_raw[0]
                require(log_id not in log_ids, "duplicate quest log entry ID")
                log_ids.add(log_id)
                log = {"id": log_id, "hasData": has_data_raw[0] != 0}
                if log["hasData"]:
                    require(pos + 2 <= len(payload), "truncated quest log data prefix")
                    first = int.from_bytes(payload[pos : pos + 2], "little")
                    pos += 2
                    second_raw, pos = read_terminated(payload, pos, 2, "quest log data")
                    log["data"] = [first, int.from_bytes(second_raw, "little")]
                logs.append(log)
            result["stages"].append({"id": stage_id, "done": status_raw[0] != 0, "status": status_raw[0], "logs": logs})
    if form.flags & (1 << 30):
        result["scriptState"], pos = decode_script_event_list(payload, pos, form_ids, form.version)
    if form.flags & (1 << 29):
        objective_count, pos = read_counter_terminated(payload, pos, "quest objectives")
        objective_ids = set()
        for _ in range(objective_count):
            objective_raw, pos = read_terminated(payload, pos, 4, "quest objective ID")
            data_raw, pos = read_terminated(payload, pos, 4, "quest objective data")
            objective_id = int.from_bytes(objective_raw, "little", signed=True)
            require(objective_id not in objective_ids, "duplicate quest objective ID")
            objective_ids.add(objective_id)
            result["objectives"].append({"id": objective_id, "flags": int.from_bytes(data_raw, "little")})
    require(pos == len(payload), f"quest change form has {len(payload) - pos} trailing bytes")
    result["bytes"] = pos
    return result


def decode_changed_extra_summary(
    form: "RawChangeForm", form_ids: list[int], initial_state: dict[str, Any] | None
) -> dict[str, Any] | None:
    """Fully walk only the small audited extra-type subset; reject all others."""
    if form.change_type not in (0, 1, 2):
        return None
    if form.change_type in (1, 2) and decode_refid(form.refid, form_ids).get("resolvedFormId") == "0x00000014":
        return None
    mask = 0xA4061840 if form.change_type in (1, 2) else 0xA4021C40
    if not form.flags & mask:
        return None
    payload, pos = form.payload, int((initial_state or {}).get("bytes", 0))
    if form.change_type in (1, 2):
        _, pos = read_terminated(payload, pos, 1, "actor process level")
    if form.flags & 1:
        _, pos = read_terminated(payload, pos, 4, "reference flags")
    if form.flags & (1 << 4):
        _, pos = read_terminated(payload, pos, 4, "reference scale")
    extra_count, pos = read_counter_terminated(payload, pos, "changed-extra")
    types = []
    script_state = None
    for extra_index in range(extra_count):
        type_raw, type_end = read_terminated(payload, pos, 1, "extra type")
        extra_type = type_raw[0]
        types.append(extra_type)
        if extra_type == 0x0D:
            require(script_state is None, "duplicate ExtraScript in changed-extra list")
            pos = type_end
            script_raw, pos = read_terminated(payload, pos, 3, "script RefID")
            event_list, pos = decode_script_event_list(payload, pos, form_ids, form.version)
            script_state = {
                "coverage": "fully-walked-extra-list",
                "extraCount": extra_count,
                "script": decode_refid(int.from_bytes(script_raw, "big"), form_ids),
                **event_list,
                "bytesThroughScript": pos,
            }
        elif extra_type == 0x18:  # Package Start Location
            pos = type_end
            _, pos = read_terminated(payload, pos, 3, "package-start cell")
            _, pos = read_terminated(payload, pos, 12, "package-start position")
            _, pos = read_terminated(payload, pos, 4, "package-start unknown")
        elif extra_type == 0x1D:  # Follower Array
            pos = type_end
            count, pos = read_counter_terminated(payload, pos, "follower array")
            for _ in range(count):
                _, pos = read_terminated(payload, pos, 3, "follower RefID")
        elif extra_type == 0x2E:  # Leveled Creature, only null nested actor-base branch
            pos = type_end
            _, pos = read_terminated(payload, pos, 3, "leveled actor base")
            _, pos = read_terminated(payload, pos, 3, "selected actor base")
            flags_raw, pos = read_terminated(payload, pos, 4, "changed actor-base flags")
            if int.from_bytes(flags_raw, "little") != 0:
                if script_state is not None:
                    script_state["coverage"] = "decoded-before-opaque-later-extra"
                return {"extraCount": extra_count, "extraTypes": types, "fullyDecoded": False,
                        "extraListFullyDecoded": False,
                        "reason": "nested-actor-base-change-unsupported", "scriptState": script_state}
        else:
            if script_state is not None:
                script_state["coverage"] = "decoded-before-opaque-later-extra"
            return {"extraCount": extra_count, "extraTypes": types, "fullyDecoded": False,
                    "extraListFullyDecoded": False,
                    "reason": "unsupported-extra-type", "scriptState": script_state}
    return {"extraCount": extra_count, "extraTypes": types, "fullyDecoded": True,
            "extraListFullyDecoded": True, "scriptState": script_state}


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
    script_state_counts = Counter()
    quest_state_counts = Counter()
    for index, form in enumerate(forms):
        ref = decode_refid(form.refid, form_ids)
        unresolved += ref["resolvedFormId"] is None
        resolved_number = int(ref["resolvedFormId"], 16) if ref["resolvedFormId"] is not None else None
        semantic = semantic_placements.get(resolved_number) if resolved_number is not None else None
        initial_state = decode_initial_state(form, form_ids)
        changed_extra_state = decode_changed_extra_summary(form, form_ids, initial_state)
        script_state = (changed_extra_state or {}).get("scriptState")
        quest_state = decode_quest_state(form, form_ids)
        if initial_state is not None:
            initial_state_counts[initial_state["kind"]] += 1
        if script_state is not None:
            script_state_counts["references"] += 1
            for variable in script_state["variables"]:
                script_state_counts[f"{variable['kind']}Variables"] += 1
        if quest_state is not None:
            quest_state_counts["quests"] += 1
            quest_state_counts["stages"] += len(quest_state["stages"])
            quest_state_counts["objectives"] += len(quest_state["objectives"])
            quest_script_state = quest_state.get("scriptState")
            if quest_script_state is not None:
                quest_state_counts["scriptEventLists"] += 1
                for variable in quest_script_state["variables"]:
                    quest_state_counts[f"{variable['kind']}Variables"] += 1
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
            "semanticCoverage": "+".join(filter(None, [
                "initial-state" if initial_state is not None else "",
                "script-event-state" if script_state is not None else "",
                "quest-state" if quest_state is not None else "",
            ])) or "opaque",
            "initialState": initial_state,
            "scriptState": script_state,
            "changedExtraState": changed_extra_state,
            "questState": quest_state,
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
            "decodedReferenceScriptState": dict(sorted(script_state_counts.items())),
            "decodedQuestState": dict(sorted(quest_state_counts.items())),
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
            "payloadSemantics": "partial-fail-closed",
            "note": "Fixed reference initial data, ordered ExtraScript event-list state, and complete QUST change forms are promoted; partial extra lists and remaining payload bytes stay explicitly opaque.",
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
