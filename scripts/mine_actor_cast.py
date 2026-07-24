#!/usr/bin/env python3
import argparse
import json
import math
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from export_esm4_catalog import ESM4Catalog


PRIMARY_CONTENT = {
    "oblivion": "Oblivion.esm",
    "fallout3": "Fallout3.esm",
    "fallout_new_vegas": "FalloutNV.esm",
    "skyrim_vr": "Skyrim.esm",
    "fallout4": "Fallout4.esm",
    "fallout4_vr": "Fallout4.esm",
    "starfield": "Starfield.esm",
}

START_TERMS = {
    "oblivion": ["imperial", "palace", "market", "prison"],
    "fallout3": ["megaton", "vault101", "springvale"],
    "fallout_new_vegas": ["goodsprings", "primm", "novac"],
    "skyrim_vr": ["riverwood", "whiterun", "helgen"],
    "fallout4": ["sanctuary", "prewar", "concord", "vault111", "codsworth"],
    "fallout4_vr": ["sanctuary", "prewar", "concord", "vault111", "codsworth"],
    "starfield": ["newatlantis", "spaceport", "lodge", "akila", "neon"],
}

BUCKET_ORDER = [
    "start_area",
    "named",
    "adult_male",
    "adult_female",
    "child",
    "guard_or_soldier",
    "robot",
    "creature",
    "animal",
    "monster",
    "leveled_actor",
    "unknown_actor",
]


def form_int(hex_id):
    if not hex_id:
        return None
    try:
        return int(hex_id, 16)
    except ValueError:
        return None


def find_content(data_paths, filename):
    for data_path in data_paths or []:
        candidate = Path(data_path) / filename
        if candidate.exists():
            return candidate
    return None


def record_text(*records):
    pieces = []
    for record in records:
        if not record:
            continue
        for key in ("editorId", "fullName", "type"):
            value = record.get(key)
            if value:
                pieces.append(str(value))
    return " ".join(pieces).lower()


def has_any(text, terms):
    return any(term in text for term in terms)


def looks_named_editor(editor_id):
    if not editor_id:
        return False
    lowered = editor_id.lower()
    generic_prefixes = (
        "lvl",
        "enc",
        "mq101neighbor",
        "mq101fence",
        "guard",
        "cwsiege",
        "cwsoldier",
        "dun",
        "treas",
        "dn0",
    )
    generic_terms = ("template", "patrol", "soldier", "guard", "ambush", "leveled", "corpse")
    return not lowered.startswith(generic_prefixes) and not any(term in lowered for term in generic_terms)


def get_record(records, hex_id):
    value = form_int(hex_id)
    return records.get(value) if value is not None else None


def resolve_leveled_samples(base_record, records, depth=0, seen=None):
    if not base_record or base_record.get("type") not in ("LVLN", "LVLC") or depth > 2:
        return []
    seen = seen or set()
    out = []
    for entry in base_record.get("leveledEntries", [])[:24]:
        if entry in seen:
            continue
        seen.add(entry)
        record = get_record(records, entry)
        if not record:
            out.append({"id": entry, "type": "missing"})
            continue
        sample = {
            "id": record.get("id"),
            "openmwId": record.get("openmwId"),
            "type": record.get("type"),
            "editorId": record.get("editorId", ""),
            "fullName": record.get("fullName", ""),
        }
        race = get_record(records, record.get("race"))
        if race:
            sample["raceEditorId"] = race.get("editorId", "")
            sample["raceFullName"] = race.get("fullName", "")
        out.append(sample)
        if record.get("type") in ("LVLN", "LVLC"):
            out.extend(resolve_leveled_samples(record, records, depth + 1, seen)[:8])
    return out[:24]


def classify_candidate(world_id, placement, base_record, race_record, leveled_samples, cell):
    labels = set()
    base_type = (base_record or {}).get("type", "")
    core_text = record_text(base_record, cell)
    race_text = record_text(race_record)
    sample_text = " ".join(
        " ".join(str(sample.get(key, "")) for key in ("type", "editorId", "fullName", "raceEditorId", "raceFullName"))
        for sample in leveled_samples
    ).lower()
    all_text = f"{core_text} {race_text} {sample_text}"
    creature_text = f"{core_text} {sample_text}"

    if placement.get("type") == "ACRE" or base_type == "CREA" or any(sample.get("type") == "CREA" for sample in leveled_samples):
        labels.add("creature")
    if base_type in ("LVLN", "LVLC"):
        labels.add("leveled_actor")
    if (base_record or {}).get("fullName") or looks_named_editor((base_record or {}).get("editorId", "")):
        labels.add("named")
    if has_any(core_text, ("guard", "soldier", "raider", "ncr", "legion", "brotherhood", "imperial", "stormcloak", "security")):
        labels.add("guard_or_soldier")
    if has_any(all_text, ("child", "boy", "girl", "kid")):
        labels.add("child")
    if has_any(
        all_text,
        ("robot", "protectron", "mrhandy", "misterhandy", "handyrace", "codsworth", "gutsy", "sentrybot", "assaultron", "eyebot"),
    ):
        labels.add("robot")
    if has_any(creature_text, ("dog", "wolf", "horse", "brahmin", "cow", "molerat", "radstag", "goat", "chicken", "fox", "deer")):
        labels.add("animal")
        labels.add("creature")
    if has_any(
        creature_text,
        (
            "radroach",
            "deathclaw",
            "mirelurk",
            "supermutant",
            "ghoul",
            "trollrace",
            "frosttroll",
            "draugr",
            "dragonrace",
            "dragonpriest",
            "encdragon",
            "spider",
            "skeletonrace",
            "spriggan",
            "atronach",
            "scorpion",
            "gecko",
        )
    ):
        labels.add("monster")
        labels.add("creature")

    actorish = base_type == "NPC_" or any(sample.get("type") == "NPC_" for sample in leveled_samples)
    non_human = labels.intersection({"child", "robot", "creature", "animal", "monster"})
    if actorish and not non_human:
        female = (base_record or {}).get("femaleFlag")
        if female is True or any(term in all_text for term in ("female", "woman", "girl")):
            labels.add("adult_female")
        elif female is False or any(term in all_text for term in ("male", "man", "boy")):
            labels.add("adult_male")

    start_terms = START_TERMS.get(world_id, [])
    if any(term in all_text for term in start_terms):
        labels.add("start_area")

    if not labels:
        labels.add("unknown_actor")
    return sorted(labels, key=lambda label: BUCKET_ORDER.index(label) if label in BUCKET_ORDER else 999)


def score_candidate(world_id, placement, base_record, race_record, labels, cell):
    score = 0
    if placement.get("pos"):
        score += 50
    if cell and cell.get("isExterior"):
        score += 25
    if base_record and base_record.get("type") in ("NPC_", "CREA"):
        score += 30
    if base_record and base_record.get("type") in ("LVLN", "LVLC"):
        score += 12
    if base_record and base_record.get("fullName"):
        score += 20
    if "start_area" in labels:
        score += 25
    if "named" in labels:
        score += 12
    if "robot" in labels or "child" in labels:
        score += 10
    if "creature" in labels or "monster" in labels:
        score += 8
    if "guard_or_soldier" in labels:
        score += 6
    if cell and cell.get("actorTotalRefCount"):
        score += min(20, cell.get("actorTotalRefCount", 0))
    return score


def camera_plan_for(pos, rot=None, distance=420.0):
    if not pos:
        return None
    z = pos[2]
    yaw = rot[2] if rot and len(rot) >= 3 else math.radians(45)
    # Stand in front of the actor when rotation is available; otherwise use a stable diagonal.
    cam_x = pos[0] - math.sin(yaw) * distance
    cam_y = pos[1] - math.cos(yaw) * distance
    return {
        "position": {"x": round(cam_x, 3), "y": round(cam_y, 3), "z": round(z + 115, 3)},
        "target": {"x": round(pos[0], 3), "y": round(pos[1], 3), "z": round(z + 85, 3)},
    }


def build_candidate(world_id, placement, base_record, race_record, leveled_samples, labels, score, cell):
    pos = placement.get("pos")
    return {
        "score": score,
        "labels": labels,
        "ref": placement.get("id"),
        "openmwRef": placement.get("openmwId"),
        "placementType": placement.get("type"),
        "base": placement.get("base"),
        "openmwBase": placement.get("openmwBase"),
        "baseType": (base_record or {}).get("type", "missing"),
        "baseEditorId": (base_record or {}).get("editorId", ""),
        "baseFullName": (base_record or {}).get("fullName", ""),
        "race": (base_record or {}).get("race"),
        "raceEditorId": (race_record or {}).get("editorId", ""),
        "raceFullName": (race_record or {}).get("fullName", ""),
        "femaleFlag": (base_record or {}).get("femaleFlag"),
        "cell": {
            "id": (cell or {}).get("id"),
            "openmwId": (cell or {}).get("openmwId"),
            "editorId": (cell or {}).get("editorId", ""),
            "fullName": (cell or {}).get("fullName", ""),
            "isExterior": (cell or {}).get("isExterior"),
            "parentWorld": (cell or {}).get("parentWorld"),
            "grid": {"x": (cell or {}).get("x"), "y": (cell or {}).get("y")},
        },
        "pos": pos,
        "rot": placement.get("rot"),
        "camera": camera_plan_for(pos, placement.get("rot")),
        "leveledSamples": leveled_samples[:8],
    }


def compact_candidate(candidate):
    keys = [
        "score",
        "labels",
        "ref",
        "openmwRef",
        "placementType",
        "base",
        "baseType",
        "baseEditorId",
        "baseFullName",
        "raceEditorId",
        "cell",
        "pos",
        "rot",
        "camera",
        "leveledSamples",
    ]
    return {key: candidate[key] for key in keys if key in candidate and candidate[key] not in (None, "", [], {})}


def cell_cast_summary(world_id, cell, candidates):
    labels = sorted({label for candidate in candidates for label in candidate["labels"]})
    actor_positions = [candidate["pos"] for candidate in candidates if candidate.get("pos")]
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

    start_score = 20 if "start_area" in labels else 0
    diversity_score = len(labels) * 10
    concrete_score = sum(1 for candidate in candidates if candidate["baseType"] in ("NPC_", "CREA")) * 6
    exterior_score = 20 if cell.get("isExterior") else 0
    score = start_score + diversity_score + concrete_score + exterior_score + min(len(candidates), 30)

    return {
        "score": score,
        "cell": {
            "id": cell.get("id"),
            "openmwId": cell.get("openmwId"),
            "editorId": cell.get("editorId", ""),
            "fullName": cell.get("fullName", ""),
            "isExterior": cell.get("isExterior"),
            "parentWorld": cell.get("parentWorld"),
            "grid": {"x": cell.get("x"), "y": cell.get("y")},
        },
        "labels": labels,
        "actorCount": len(candidates),
        "concreteActorCount": sum(1 for candidate in candidates if candidate["baseType"] in ("NPC_", "CREA")),
        "leveledActorCount": sum(1 for candidate in candidates if candidate["baseType"] in ("LVLN", "LVLC")),
        "center": [round(value, 3) for value in center] if center else None,
        "spread": round(spread, 3) if spread is not None else None,
        "camera": camera,
        "cast": [compact_candidate(candidate) for candidate in sorted(candidates, key=lambda c: c["score"], reverse=True)[:12]],
    }


def mine_world(world, out_dir, top_cast, top_cells):
    world_id = world.get("id")
    primary = PRIMARY_CONTENT.get(world_id)
    if not primary:
        return {
            "worldId": world_id,
            "status": "skipped",
            "reason": "No TES4-family primary plugin is configured for this world.",
        }

    esm = find_content(world.get("dataPaths"), primary)
    if not esm:
        return {
            "worldId": world_id,
            "status": "missing",
            "primaryContent": primary,
            "reason": "Primary plugin was not found in detected data paths.",
        }

    terms = sorted(set(START_TERMS.get(world_id, []) + ["codsworth", "guard", "child", "female", "male", "creature"]))
    catalog = ESM4Catalog(esm, mod_index=0, terms=terms)
    catalog.parse()

    candidates = []
    by_cell = defaultdict(list)
    for placement in catalog.placements:
        if placement.get("type") not in ("ACHR", "ACRE") or not placement.get("pos"):
            continue
        base_record = get_record(catalog.records, placement.get("base"))
        race_record = get_record(catalog.records, (base_record or {}).get("race"))
        leveled_samples = resolve_leveled_samples(base_record, catalog.records)
        cell = get_record(catalog.cells, placement.get("parentCell"))
        labels = classify_candidate(world_id, placement, base_record, race_record, leveled_samples, cell)
        score = score_candidate(world_id, placement, base_record, race_record, labels, cell)
        candidate = build_candidate(world_id, placement, base_record, race_record, leveled_samples, labels, score, cell)
        candidates.append(candidate)
        if placement.get("parentCell"):
            by_cell[placement["parentCell"]].append(candidate)

    buckets = {}
    for bucket in BUCKET_ORDER:
        bucket_items = [candidate for candidate in candidates if bucket in candidate["labels"]]
        bucket_items.sort(key=lambda c: c["score"], reverse=True)
        if bucket_items:
            buckets[bucket] = [compact_candidate(candidate) for candidate in bucket_items[:top_cast]]

    cell_summaries = []
    for cell_id, cell_candidates in by_cell.items():
        cell = get_record(catalog.cells, cell_id)
        if not cell:
            continue
        cell_summaries.append(cell_cast_summary(world_id, cell, cell_candidates))
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
            "records": len(catalog.records),
            "cells": len(catalog.cells),
            "placements": len(catalog.placements),
            "actorPlacements": len(candidates),
            "actorCells": len(by_cell),
        },
        "representativeBuckets": buckets,
        "topCastCandidates": [compact_candidate(candidate) for candidate in sorted(candidates, key=lambda c: c["score"], reverse=True)[:top_cast]],
        "topActorCells": cell_summaries[:top_cells],
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{world_id}.actor-cast.esm4-mined.json"
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
    parser = argparse.ArgumentParser(description="Mine public-safe actor placement/cast telemetry from local TES4-family ESMs.")
    parser.add_argument("--worlds-local", default="catalog/worlds.local.json")
    parser.add_argument("--world-id", action="append", default=[])
    parser.add_argument("--out-dir", default="catalog/cells")
    parser.add_argument("--top-cast", type=int, default=24)
    parser.add_argument("--top-cells", type=int, default=80)
    args = parser.parse_args()

    worlds_path = Path(args.worlds_local)
    worlds_local = json.loads(worlds_path.read_text(encoding="utf-8"))
    wanted = set(args.world_id)
    worlds = [
        world
        for world in worlds_local.get("worlds", [])
        if (not wanted or world.get("id") in wanted) and world.get("installStatus") == "ready"
    ]
    results = [mine_world(world, Path(args.out_dir), args.top_cast, args.top_cells) for world in worlds]
    print(json.dumps({"results": results}, indent=2))


if __name__ == "__main__":
    main()
