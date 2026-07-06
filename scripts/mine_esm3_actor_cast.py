#!/usr/bin/env python3
import argparse
import json
import math
import re
import struct
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


PRIMARY_CONTENT = {
    "morrowind": "Morrowind.esm",
}

BUCKET_ORDER = [
    "start_area",
    "named",
    "adult_male",
    "adult_female",
    "child",
    "guard_or_soldier",
    "creature",
    "animal",
    "monster",
    "unknown_actor",
]

START_TERMS = {
    "morrowind": ["seyda", "neen", "census", "fargoth", "socucius", "elone", "arrille"],
}

ENCODING_ALIASES = {
    "win1250": "cp1250",
    "win1251": "cp1251",
    "win1252": "cp1252",
}


def decode_zstring(data, encoding):
    return data.split(b"\0", 1)[0].decode(encoding, errors="replace").strip()


def read_u32(data, offset=0):
    if len(data) < offset + 4:
        return None
    return struct.unpack_from("<I", data, offset)[0]


def read_i32_triplet(data):
    if len(data) < 12:
        return None
    return struct.unpack_from("<iii", data, 0)


def read_float_triplets(data):
    if len(data) < 24:
        return None, None
    values = struct.unpack_from("<ffffff", data, 0)
    return list(values[:3]), list(values[3:])


def find_content(data_paths, filename):
    for data_path in data_paths or []:
        candidate = Path(data_path) / filename
        if candidate.exists():
            return candidate
    return None


def has_any(text, terms):
    return any(term in text for term in terms)


def has_tokenish(text, terms):
    normalized = f" {re.sub(r'[^a-z0-9]+', ' ', text.lower())} "
    return any(f" {term} " in normalized for term in terms)


def camera_plan_for(pos, rot=None, distance=420.0):
    if not pos:
        return None
    yaw = rot[2] if rot and len(rot) >= 3 else math.radians(45)
    cam_x = pos[0] - math.sin(yaw) * distance
    cam_y = pos[1] - math.cos(yaw) * distance
    return {
        "position": {"x": round(cam_x, 3), "y": round(cam_y, 3), "z": round(pos[2] + 115, 3)},
        "target": {"x": round(pos[0], 3), "y": round(pos[1], 3), "z": round(pos[2] + 85, 3)},
    }


def iter_subrecords(record_data, encoding):
    offset = 0
    while offset + 8 <= len(record_data):
        name = record_data[offset : offset + 4].decode("ascii", errors="replace")
        size = read_u32(record_data, offset + 4)
        offset += 8
        if size is None or offset + size > len(record_data):
            break
        yield name, record_data[offset : offset + size]
        offset += size


def parse_esm3(path, encoding):
    npcs = {}
    creatures = {}
    races = {}
    cells = []

    with path.open("rb") as handle:
        while True:
            header = handle.read(16)
            if not header:
                break
            if len(header) < 16:
                raise ValueError(f"Truncated record header in {path}")
            record_type = header[:4].decode("ascii", errors="replace")
            size = read_u32(header, 4)
            if size is None:
                raise ValueError(f"Invalid record size in {path}")
            data = handle.read(size)
            if len(data) != size:
                raise ValueError(f"Truncated {record_type} record in {path}")

            if record_type == "NPC_":
                record = {"type": "NPC_", "id": "", "fullName": "", "race": "", "femaleFlag": None}
                for sub_name, sub_data in iter_subrecords(data, encoding):
                    if sub_name == "NAME":
                        record["id"] = decode_zstring(sub_data, encoding)
                    elif sub_name == "FNAM":
                        record["fullName"] = decode_zstring(sub_data, encoding)
                    elif sub_name == "RNAM":
                        record["race"] = decode_zstring(sub_data, encoding)
                    elif sub_name == "FLAG":
                        flags = read_u32(sub_data)
                        if flags is not None:
                            record["femaleFlag"] = bool(flags & 0x1)
                if record["id"]:
                    npcs[record["id"].lower()] = record
            elif record_type == "CREA":
                record = {"type": "CREA", "id": "", "fullName": ""}
                for sub_name, sub_data in iter_subrecords(data, encoding):
                    if sub_name == "NAME":
                        record["id"] = decode_zstring(sub_data, encoding)
                    elif sub_name == "FNAM":
                        record["fullName"] = decode_zstring(sub_data, encoding)
                if record["id"]:
                    creatures[record["id"].lower()] = record
            elif record_type == "RACE":
                record = {"type": "RACE", "id": "", "fullName": ""}
                for sub_name, sub_data in iter_subrecords(data, encoding):
                    if sub_name == "NAME":
                        record["id"] = decode_zstring(sub_data, encoding)
                    elif sub_name == "FNAM":
                        record["fullName"] = decode_zstring(sub_data, encoding)
                if record["id"]:
                    races[record["id"].lower()] = record
            elif record_type == "CELL":
                cells.append(parse_cell(data, encoding))

    return {"npcs": npcs, "creatures": creatures, "races": races, "cells": cells}


def parse_cell(record_data, encoding):
    cell = {
        "id": None,
        "openmwId": None,
        "editorId": "",
        "fullName": "",
        "isExterior": None,
        "parentWorld": None,
        "grid": {"x": None, "y": None},
        "placements": [],
    }
    current_ref = None

    def finish_ref():
        nonlocal current_ref
        if current_ref and current_ref.get("base") and current_ref.get("pos"):
            cell["placements"].append(current_ref)
        current_ref = None

    for sub_name, sub_data in iter_subrecords(record_data, encoding):
        if sub_name == "FRMR":
            finish_ref()
            ref_num = read_u32(sub_data)
            current_ref = {
                "id": f"0x{ref_num:x}" if ref_num is not None else None,
                "openmwId": f"MorrowindRef:0x{ref_num:x}" if ref_num is not None else None,
                "placementType": "REFR",
                "base": "",
                "openmwBase": "",
                "pos": None,
                "rot": None,
            }
        elif sub_name == "NAME":
            value = decode_zstring(sub_data, encoding)
            if current_ref is not None and not current_ref.get("base"):
                current_ref["base"] = value
                current_ref["openmwBase"] = value
            elif current_ref is None:
                cell["id"] = value
                cell["openmwId"] = value
                cell["editorId"] = value
                cell["fullName"] = value
        elif sub_name == "DATA":
            if current_ref is not None:
                pos, rot = read_float_triplets(sub_data)
                if pos:
                    current_ref["pos"] = pos
                    current_ref["rot"] = rot
            else:
                triplet = read_i32_triplet(sub_data)
                if triplet:
                    flags, x, y = triplet
                    cell["isExterior"] = bool(flags & 0x1)
                    cell["grid"] = {"x": x, "y": y}
                    if cell["isExterior"]:
                        cell["id"] = cell["id"] or f"Exterior {x},{y}"
                        cell["openmwId"] = cell["id"]
                        cell["editorId"] = cell["id"]
                        cell["fullName"] = cell["fullName"] or cell["id"]

    finish_ref()
    if cell["isExterior"] is None:
        cell["isExterior"] = False
    return cell


def classify_candidate(world_id, placement, base_record, race_record, cell):
    labels = set()
    cell_text = " ".join(str(cell.get(key, "")) for key in ("editorId", "fullName")).lower()
    base_text = " ".join(str(base_record.get(key, "")) for key in ("id", "fullName", "type")).lower()
    race_text = " ".join(str((race_record or {}).get(key, "")) for key in ("id", "fullName")).lower()
    all_text = f"{cell_text} {base_text} {race_text}"

    if has_any(all_text, START_TERMS.get(world_id, [])):
        labels.add("start_area")
    if base_record.get("type") == "CREA":
        labels.add("creature")
    if base_record.get("fullName"):
        labels.add("named")
    if has_tokenish(all_text, ("guard", "soldier", "ordinator", "legion", "watch", "templar")) or "buoyant armiger" in all_text:
        labels.add("guard_or_soldier")
    if has_tokenish(all_text, ("child", "kid")):
        labels.add("child")

    if base_record.get("type") == "CREA" and has_tokenish(
        all_text,
        ("rat", "scrib", "guar", "kagouti", "netch", "mudcrab", "kwama", "hound", "fish", "slaughterfish"),
    ):
        labels.add("animal")
    if base_record.get("type") == "CREA" and (
        has_tokenish(
            all_text,
            (
                "daedra",
                "dremora",
                "atronach",
                "ghost",
                "skeleton",
                "zombie",
                "vampire",
                "ash",
                "corprus",
                "dreugh",
                "ogrim",
                "scamp",
                "saint",
                "centurion",
            ),
        )
        or "cliff racer" in all_text
        or "cliffracer" in all_text
    ):
        labels.add("monster")

    if base_record.get("type") == "NPC_" and not labels.intersection({"child", "creature"}):
        female = base_record.get("femaleFlag")
        if female is True:
            labels.add("adult_female")
        elif female is False:
            labels.add("adult_male")

    if not labels:
        labels.add("unknown_actor")
    return sorted(labels, key=lambda label: BUCKET_ORDER.index(label) if label in BUCKET_ORDER else 999)


def score_candidate(placement, base_record, labels, cell):
    label_set = set(labels)
    score = 0
    if placement.get("pos"):
        score += 50
    if cell.get("isExterior"):
        score += 20
    if base_record.get("type") in ("NPC_", "CREA"):
        score += 30
    if base_record.get("fullName"):
        score += 20
    if "start_area" in labels:
        score += 25
    if "named" in labels:
        score += 12
    if "guard_or_soldier" in labels:
        score += 8
    if label_set.intersection({"creature", "animal", "monster"}):
        score += 8
    return score


def compact_candidate(candidate):
    keys = [
        "score",
        "labels",
        "ref",
        "openmwRef",
        "placementType",
        "base",
        "openmwBase",
        "baseType",
        "baseEditorId",
        "baseFullName",
        "raceEditorId",
        "raceFullName",
        "cell",
        "pos",
        "rot",
        "camera",
    ]
    return {key: candidate[key] for key in keys if key in candidate and candidate[key] not in (None, "", [], {})}


def build_candidate(world_id, placement, base_record, race_record, labels, score, cell):
    return {
        "score": score,
        "labels": labels,
        "ref": placement.get("id"),
        "openmwRef": placement.get("openmwId"),
        "placementType": placement.get("placementType"),
        "base": placement.get("base"),
        "openmwBase": placement.get("openmwBase"),
        "baseType": base_record.get("type", "missing"),
        "baseEditorId": base_record.get("id", ""),
        "baseFullName": base_record.get("fullName", ""),
        "raceEditorId": (race_record or {}).get("id", ""),
        "raceFullName": (race_record or {}).get("fullName", ""),
        "cell": {
            "id": cell.get("id"),
            "openmwId": cell.get("openmwId"),
            "editorId": cell.get("editorId", ""),
            "fullName": cell.get("fullName", ""),
            "isExterior": cell.get("isExterior"),
            "parentWorld": cell.get("parentWorld"),
            "grid": cell.get("grid"),
        },
        "pos": placement.get("pos"),
        "rot": placement.get("rot"),
        "camera": camera_plan_for(placement.get("pos"), placement.get("rot")),
    }


def cell_cast_summary(cell, candidates):
    actor_positions = [candidate["pos"] for candidate in candidates if candidate.get("pos")]
    labels = sorted({label for candidate in candidates for label in candidate["labels"]})
    center = None
    spread = None
    camera = None
    if actor_positions:
        center = [sum(pos[i] for pos in actor_positions) / len(actor_positions) for i in range(3)]
        spread = math.sqrt(
            sum((pos[0] - center[0]) ** 2 + (pos[1] - center[1]) ** 2 for pos in actor_positions)
            / len(actor_positions)
        )
        camera = {
            "position": {
                "x": round(center[0] + max(520.0, min(1200.0, spread + 360.0)), 3),
                "y": round(center[1] - max(380.0, min(900.0, spread * 0.5 + 240.0)), 3),
                "z": round(center[2] + 130.0, 3),
            },
            "target": {"x": round(center[0], 3), "y": round(center[1], 3), "z": round(center[2] + 80.0, 3)},
        }

    return {
        "score": len(labels) * 10 + len(candidates),
        "cell": {
            "id": cell.get("id"),
            "openmwId": cell.get("openmwId"),
            "editorId": cell.get("editorId", ""),
            "fullName": cell.get("fullName", ""),
            "isExterior": cell.get("isExterior"),
            "parentWorld": cell.get("parentWorld"),
            "grid": cell.get("grid"),
        },
        "labels": labels,
        "actorCount": len(candidates),
        "concreteActorCount": len(candidates),
        "leveledActorCount": 0,
        "center": [round(value, 3) for value in center] if center else None,
        "spread": round(spread, 3) if spread is not None else None,
        "camera": camera,
        "cast": [compact_candidate(candidate) for candidate in sorted(candidates, key=lambda c: c["score"], reverse=True)[:12]],
    }


def mine_world(world, out_dir, top_cast, top_cells, encoding):
    world_id = world.get("id")
    primary = PRIMARY_CONTENT.get(world_id)
    if not primary:
        return {"worldId": world_id, "status": "skipped", "reason": "No ESM3 primary plugin is configured."}

    esm = find_content(world.get("dataPaths"), primary)
    if not esm:
        return {
            "worldId": world_id,
            "status": "missing",
            "primaryContent": primary,
            "reason": "Primary plugin was not found in detected data paths.",
        }

    parsed = parse_esm3(esm, encoding)
    records_by_id = {**parsed["npcs"], **parsed["creatures"]}
    candidates = []
    by_cell = defaultdict(list)

    for cell in parsed["cells"]:
        for placement in cell["placements"]:
            base_record = records_by_id.get(placement.get("base", "").lower())
            if not base_record:
                continue
            race_record = parsed["races"].get(base_record.get("race", "").lower())
            labels = classify_candidate(world_id, placement, base_record, race_record, cell)
            score = score_candidate(placement, base_record, labels, cell)
            candidate = build_candidate(world_id, placement, base_record, race_record, labels, score, cell)
            candidates.append(candidate)
            by_cell[cell.get("id") or f"{cell['grid'].get('x')},{cell['grid'].get('y')}"].append(candidate)

    buckets = {}
    for bucket in BUCKET_ORDER:
        bucket_items = [candidate for candidate in candidates if bucket in candidate["labels"]]
        bucket_items.sort(key=lambda c: c["score"], reverse=True)
        if bucket_items:
            buckets[bucket] = [compact_candidate(candidate) for candidate in bucket_items[:top_cast]]

    cell_summaries = []
    cell_by_id = {cell.get("id") or f"{cell['grid'].get('x')},{cell['grid'].get('y')}": cell for cell in parsed["cells"]}
    for cell_id, cell_candidates in by_cell.items():
        cell = cell_by_id.get(cell_id)
        if cell:
            cell_summaries.append(cell_cast_summary(cell, cell_candidates))
    cell_summaries.sort(key=lambda c: c["score"], reverse=True)

    output = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "assetPolicy": "Generated metadata only. Do not commit retail assets, screenshots, logs, or local profile output.",
        "worldId": world_id,
        "displayName": world.get("displayName", world_id),
        "primaryContent": primary,
        "source": str(esm),
        "counts": {
            "npcRecords": len(parsed["npcs"]),
            "creatureRecords": len(parsed["creatures"]),
            "raceRecords": len(parsed["races"]),
            "cells": len(parsed["cells"]),
            "actorPlacements": len(candidates),
            "actorCells": len(by_cell),
        },
        "representativeBuckets": buckets,
        "topCastCandidates": [compact_candidate(candidate) for candidate in sorted(candidates, key=lambda c: c["score"], reverse=True)[:top_cast]],
        "topActorCells": cell_summaries[:top_cells],
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{world_id}.actor-cast.esm3-mined.json"
    out_path.write_text(json.dumps(output, indent=2), encoding="ascii")
    return {
        "worldId": world_id,
        "status": "written",
        "out": str(out_path),
        "counts": output["counts"],
        "topActorCells": [
            {
                "editorId": item["cell"].get("editorId"),
                "actorCount": item["actorCount"],
                "labels": item["labels"],
                "score": item["score"],
            }
            for item in output["topActorCells"][:8]
        ],
    }


def main():
    parser = argparse.ArgumentParser(description="Mine public-safe Morrowind/TES3 actor placement metadata.")
    parser.add_argument("--worlds-local", default="catalog/worlds.local.json")
    parser.add_argument("--world-id", action="append", default=["morrowind"])
    parser.add_argument("--out-dir", default="catalog/cells")
    parser.add_argument("--top-cast", type=int, default=24)
    parser.add_argument("--top-cells", type=int, default=80)
    parser.add_argument("--encoding", default="win1252")
    args = parser.parse_args()

    encoding = ENCODING_ALIASES.get(args.encoding.lower(), args.encoding)
    worlds_path = Path(args.worlds_local)
    worlds_local = json.loads(worlds_path.read_text(encoding="utf-8"))
    wanted = set(args.world_id)
    worlds = [
        world
        for world in worlds_local.get("worlds", [])
        if (not wanted or world.get("id") in wanted) and world.get("installStatus") == "ready"
    ]
    results = [mine_world(world, Path(args.out_dir), args.top_cast, args.top_cells, encoding) for world in worlds]
    print(json.dumps({"results": results}, indent=2))


if __name__ == "__main__":
    main()
