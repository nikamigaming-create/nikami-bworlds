#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


WORLD_ORDER = [
    "morrowind",
    "oblivion",
    "fallout3",
    "fallout_new_vegas",
    "skyrim_2011",
    "skyrim_vr",
    "fallout4",
    "fallout4_vr",
    "fallout76",
    "starfield",
]

CANONICAL_BUCKETS = [
    {
        "id": "usual_suspects",
        "label": "usual suspects",
        "sourceBuckets": ["start_area", "named", "robot"],
        "description": "Named or highly recognizable actors near useful starter/adventure areas.",
    },
    {
        "id": "adult_male",
        "label": "adult male",
        "sourceBuckets": ["adult_male"],
        "description": "One or more ordinary male humanoid actors.",
    },
    {
        "id": "adult_female",
        "label": "adult female",
        "sourceBuckets": ["adult_female"],
        "description": "One or more ordinary female humanoid actors.",
    },
    {
        "id": "child",
        "label": "child",
        "sourceBuckets": ["child"],
        "description": "Child actors where the game has them.",
    },
    {
        "id": "guard_or_soldier",
        "label": "guard or soldier",
        "sourceBuckets": ["guard_or_soldier"],
        "description": "A faction guard, soldier, raider, security, or equivalent combatant.",
    },
    {
        "id": "robot",
        "label": "robot",
        "sourceBuckets": ["robot"],
        "description": "Robots or mechanical humanoid actors where present.",
    },
    {
        "id": "animal",
        "label": "animal",
        "sourceBuckets": ["animal"],
        "description": "Non-monstrous animals and livestock.",
    },
    {
        "id": "creature",
        "label": "creature",
        "sourceBuckets": ["creature"],
        "description": "Creature records that should exercise non-human actor loading.",
    },
    {
        "id": "monster",
        "label": "monster",
        "sourceBuckets": ["monster"],
        "description": "Hostile or supernatural monsters that should prove the weird body paths.",
    },
]

GENERIC_EDITOR_PREFIXES = (
    "lvl",
    "enc",
    "dun",
    "treas",
    "template",
    "test",
    "mq101neighbor",
    "cwsoldier",
    "cwsiege",
)

GENERIC_EDITOR_IDS = {
    "stump",
}

GENERIC_FULL_NAMES = {
    "",
    "guard",
    "soldier",
    "raider",
    "settler",
    "goodsprings settler",
    "ncr trooper",
    "imperial watch",
    "security",
    "brahmin",
    "horse",
    "dog",
    "radroach",
    "gecko",
    "mudcrab",
}

NO_CHILD_WORLDS = {"morrowind", "oblivion"}
NO_ROBOT_WORLDS = {"morrowind", "oblivion", "skyrim_2011", "skyrim_vr"}

VISIT_BIAS = {
    "morrowind": [
        "fargoth",
        "sellus gravius",
        "socusius ergalla",
        "socucius ergalla",
        "arrille",
        "elone",
        "jiub",
        "ganciele douar",
    ],
    "oblivion": [
        "baurus",
        "uriell",
        "uriel",
        "jauffre",
        "ocato",
        "beggaricmarketsimplicia",
        "simplicia",
        "icmarketguard",
        "imperial legion soldier",
    ],
    "fallout3": [
        "wadsworth",
        "moira brown",
        "lucas simms",
        "harden simms",
        "amata",
        "butch",
        "dad",
        "brahmin",
        "eyebot",
    ],
    "fallout_new_vegas": [
        "sunny smiles",
        "gssunnysmiles",
        "trudy",
        "gstrudy",
        "victor",
        "gsvictordisabled",
        "ringo",
        "gsringo",
        "goodsprings settler",
        "gecko",
    ],
    "skyrim_vr": [
        "haming",
        "gerdur",
        "alvor",
        "frodnar",
        "dorthe",
        "guardriverwood",
        "riverwood",
        "mq101stormcloak",
        "mq101imperial",
    ],
    "fallout4_vr": [
        "codsworth",
        "preston garvey",
        "prestongarvey",
        "mama murphy",
        "mamamurphy",
        "dogmeat",
        "mq101rosa",
        "mq101vaulttecrep",
        "radroach",
        "deathclaw",
    ],
    "starfield": [
        "newatlantis",
        "shipservices_newatlantis",
        "uc_na_",
        "uc04_woundedsecurity",
        "spaceporttech",
        "keltonfrush",
        "vasco",
        "sarah",
    ],
}


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def clean_cell_label(cell):
    if not cell:
        return "worldspace actor cluster"
    return (
        cell.get("fullName")
        or cell.get("editorId")
        or cell.get("openmwId")
        or cell.get("id")
        or "worldspace actor cluster"
    )


def actor_label(candidate):
    return candidate.get("baseFullName") or candidate.get("baseEditorId") or candidate.get("openmwBase") or candidate.get("base")


def base_identity(candidate):
    return (
        candidate.get("baseEditorId")
        or candidate.get("baseFullName")
        or candidate.get("openmwBase")
        or candidate.get("base")
        or candidate.get("ref")
        or "unknown"
    ).lower()


def is_generic(candidate):
    editor_id = (candidate.get("baseEditorId") or "").lower()
    full_name = (candidate.get("baseFullName") or "").strip().lower()
    if editor_id in GENERIC_EDITOR_IDS:
        return True
    if any(editor_id.startswith(prefix) for prefix in GENERIC_EDITOR_PREFIXES):
        return True
    return bool(full_name) and full_name in GENERIC_FULL_NAMES


def matches_visit_bias(world_id, candidate):
    cell = candidate.get("cell") or {}
    searchable = " ".join(
        str(value)
        for value in (
            candidate.get("baseEditorId", ""),
            candidate.get("baseFullName", ""),
            cell.get("editorId", ""),
            cell.get("fullName", ""),
        )
    ).lower()
    return any(term in searchable for term in VISIT_BIAS.get(world_id, []))


def is_specific_visit(world_id, candidate):
    labels = set(candidate.get("labels", []))
    if labels.intersection({"animal", "creature", "monster"}) and "robot" not in labels and not matches_visit_bias(world_id, candidate):
        return False
    if is_generic(candidate):
        return False
    return bool(candidate.get("baseFullName") or candidate.get("baseEditorId"))


def candidate_quality(world_id, candidate, bucket_id):
    labels = set(candidate.get("labels", []))
    cell = candidate.get("cell", {})
    score = int(candidate.get("score", 0) or 0)
    searchable = " ".join(
        str(value)
        for value in (
            candidate.get("baseEditorId", ""),
            candidate.get("baseFullName", ""),
            cell.get("editorId", ""),
            cell.get("fullName", ""),
        )
    ).lower()
    visit_bonus = 0
    for index, term in enumerate(VISIT_BIAS.get(world_id, [])):
        if term in searchable:
            visit_bonus = max(visit_bonus, max(80, 220 - index * 12))
    score += visit_bonus
    if candidate.get("pos"):
        score += 20
    if cell.get("isExterior"):
        score += 10
    if clean_cell_label(cell) != "worldspace actor cluster":
        score += 8
    if candidate.get("baseFullName"):
        score += 8
    if "start_area" in labels:
        score += 16
    if "named" in labels:
        score += 8
    if candidate.get("baseType") in ("LVLN", "LVLC"):
        score -= 12
    if is_generic(candidate):
        score -= 10
    if bucket_id == "usual_suspects" and not is_specific_visit(world_id, candidate):
        score -= 100
    if bucket_id in {"animal", "creature", "monster"} and candidate.get("baseType") == "NPC_":
        score -= 8
    return score


def compact_actor(candidate):
    cell = candidate.get("cell", {})
    return {
        "label": actor_label(candidate),
        "baseEditorId": candidate.get("baseEditorId", ""),
        "baseType": candidate.get("baseType", ""),
        "raceEditorId": candidate.get("raceEditorId", ""),
        "labels": candidate.get("labels", []),
        "cell": {
            "label": clean_cell_label(cell),
            "editorId": cell.get("editorId", ""),
            "openmwId": cell.get("openmwId", ""),
            "isExterior": cell.get("isExterior"),
            "grid": cell.get("grid"),
        },
        "position": candidate.get("pos"),
        "rotation": candidate.get("rot"),
    }


def runtime_validation_for(world_id, candidate):
    cell = candidate.get("cell", {})
    cell_name = cell.get("editorId") or cell.get("fullName")
    validation = {
        "launcher": "scripts/Start-WorldProfileExisting.ps1",
        "worldId": world_id,
        "actorPlacement": "engine-authored",
        "rule": "Launch the real profile and verify the actor the engine places from game data; do not stage actors or drive placement from mined coordinates.",
    }
    if cell_name:
        validation["startCell"] = cell_name
    if candidate.get("baseEditorId"):
        validation["expectedBaseEditorId"] = candidate.get("baseEditorId")
    return validation


def collect_bucket_candidates(world_id, actor_catalog, bucket_spec):
    seen = set()
    collected = []
    buckets = actor_catalog.get("representativeBuckets", {})
    for source_bucket in bucket_spec["sourceBuckets"]:
        for candidate in buckets.get(source_bucket, []):
            if bucket_spec["id"] not in {"usual_suspects"} and source_bucket not in candidate.get("labels", []):
                continue
            identity = base_identity(candidate)
            if identity in seen:
                continue
            seen.add(identity)
            collected.append(candidate)

    for cell_summary in actor_catalog.get("topActorCells", []):
        for candidate in cell_summary.get("cast", []):
            candidate_labels = set(candidate.get("labels", []))
            if bucket_spec["id"] == "usual_suspects":
                if not matches_visit_bias(world_id, candidate):
                    continue
            elif not candidate_labels.intersection(bucket_spec["sourceBuckets"]):
                continue
            identity = base_identity(candidate)
            if identity in seen:
                continue
            seen.add(identity)
            collected.append(candidate)

    if bucket_spec["id"] == "usual_suspects":
        collected = [candidate for candidate in collected if is_specific_visit(world_id, candidate)]
        if not collected:
            for candidate in buckets.get("named", []):
                identity = base_identity(candidate)
                if identity not in seen:
                    seen.add(identity)
                    collected.append(candidate)

    return sorted(collected, key=lambda candidate: candidate_quality(world_id, candidate, bucket_spec["id"]), reverse=True)


def expected_missing_bucket(world_id, bucket_id):
    if bucket_id == "child" and world_id in NO_CHILD_WORLDS:
        return True
    if bucket_id == "robot" and world_id in NO_ROBOT_WORLDS:
        return True
    return False


def build_representative_targets(world_id, actor_catalog, max_targets):
    categories = []
    gaps = []
    for bucket_spec in CANONICAL_BUCKETS:
        if expected_missing_bucket(world_id, bucket_spec["id"]):
            categories.append(
                {
                    "id": bucket_spec["id"],
                    "label": bucket_spec["label"],
                    "description": bucket_spec["description"],
                    "targets": [],
                    "expectedAbsent": True,
                }
            )
            continue
        candidates = collect_bucket_candidates(world_id, actor_catalog, bucket_spec)
        targets = []
        for candidate in candidates[:max_targets]:
            actor = compact_actor(candidate)
            actor["runtimeValidation"] = runtime_validation_for(world_id, candidate)
            targets.append(actor)
        category = {
            "id": bucket_spec["id"],
            "label": bucket_spec["label"],
            "description": bucket_spec["description"],
            "targets": targets,
        }
        if not targets and not expected_missing_bucket(world_id, bucket_spec["id"]):
            gaps.append(
                {
                    "kind": bucket_spec["id"],
                    "status": "needs-mining-or-better-classifier",
                    "note": f"No representative {bucket_spec['label']} target was selected from the mined actor cast.",
                }
            )
        categories.append(category)
    return categories, gaps


def compact_stop(stop):
    cell = stop.get("cell", {})
    return {
        "label": clean_cell_label(cell),
        "cell": {
            "editorId": cell.get("editorId", ""),
            "openmwId": cell.get("openmwId", ""),
            "isExterior": cell.get("isExterior"),
            "grid": cell.get("grid"),
        },
        "labels": stop.get("labels", []),
        "actorCount": stop.get("actorCount", 0),
        "concreteActorCount": stop.get("concreteActorCount", 0),
        "leveledActorCount": stop.get("leveledActorCount", 0),
        "center": stop.get("center"),
        "castPreview": [compact_actor(candidate) for candidate in stop.get("cast", [])[:5]],
    }


def stop_identity(stop):
    cell = stop.get("cell", {})
    return (
        (cell.get("editorId") or "").lower(),
        (cell.get("openmwId") or "").lower(),
        clean_cell_label(cell).lower(),
    )


def stop_matches_retention_spec(stop, spec):
    cell = stop.get("cell", {})
    editor_id = (cell.get("editorId") or "").lower()
    openmw_id = (cell.get("openmwId") or "").lower()
    label = clean_cell_label(cell).lower()
    spec_editor_id = (spec.get("cellEditorId") or "").lower()
    spec_openmw_id = (spec.get("cellOpenmwId") or "").lower()
    spec_label = (spec.get("label") or "").lower()
    if spec_editor_id and editor_id != spec_editor_id:
        return False
    if spec_openmw_id and openmw_id != spec_openmw_id:
        return False
    if not spec_editor_id and not spec_openmw_id and spec_label and label != spec_label:
        return False
    return bool(spec_editor_id or spec_openmw_id or spec_label)


def iter_representative_candidates(actor_catalog):
    seen = set()
    buckets = actor_catalog.get("representativeBuckets", {})
    for bucket_candidates in buckets.values():
        for candidate in bucket_candidates:
            identity = (
                candidate.get("ref")
                or candidate.get("openmwRef")
                or candidate.get("baseEditorId")
                or json.dumps(candidate.get("cell", {}), sort_keys=True)
            )
            if identity in seen:
                continue
            seen.add(identity)
            yield candidate
    for candidate in actor_catalog.get("topCastCandidates", []):
        identity = (
            candidate.get("ref")
            or candidate.get("openmwRef")
            or candidate.get("baseEditorId")
            or json.dumps(candidate.get("cell", {}), sort_keys=True)
        )
        if identity in seen:
            continue
        seen.add(identity)
        yield candidate


def compact_candidate_cell_key(candidate):
    cell = candidate.get("cell", {})
    return (
        (cell.get("editorId") or "").lower(),
        (cell.get("openmwId") or "").lower(),
        clean_cell_label(cell).lower(),
    )


def candidate_matches_retention_spec(candidate, spec):
    return stop_matches_retention_spec({"cell": candidate.get("cell", {})}, spec)


def build_synthetic_stop_from_candidates(candidates):
    first = candidates[0]
    labels = set()
    positions = []
    concrete_count = 0
    leveled_count = 0
    for candidate in candidates:
        labels.update(candidate.get("labels", []))
        pos = candidate.get("pos") or []
        if len(pos) >= 3:
            positions.append(pos)
        if candidate.get("baseType") in ("LVLN", "LVLC"):
            leveled_count += 1
        else:
            concrete_count += 1
    center = None
    if positions:
        center = [
            round(sum(pos[index] for pos in positions) / len(positions), 3)
            for index in range(3)
        ]
    return {
        "cell": first.get("cell", {}),
        "labels": sorted(labels),
        "actorCount": len(candidates),
        "concreteActorCount": concrete_count,
        "leveledActorCount": leveled_count,
        "center": center,
        "cast": candidates,
    }


def retained_candidate_stop_matches(actor_catalog, retention_specs):
    candidates_by_cell = {}
    for candidate in iter_representative_candidates(actor_catalog):
        key = compact_candidate_cell_key(candidate)
        candidates_by_cell.setdefault(key, []).append(candidate)

    matches = []
    seen = set()
    for spec in retention_specs or []:
        for key, candidates in candidates_by_cell.items():
            if key in seen:
                continue
            if not any(candidate_matches_retention_spec(candidate, spec) for candidate in candidates):
                continue
            seen.add(key)
            matches.append(build_synthetic_stop_from_candidates(candidates))
            break
    return matches


def retained_fallback_stop_matches(retention_specs):
    matches = []
    for spec in retention_specs or []:
        fallback = spec.get("fallbackStop")
        if not fallback:
            continue
        if stop_matches_retention_spec(fallback, spec):
            matches.append(fallback)
    return matches


def retained_stop_matches(actor_catalog, stops, retention_specs):
    matches = []
    seen = set()
    for spec in retention_specs or []:
        for stop in stops:
            if not stop_matches_retention_spec(stop, spec):
                continue
            key = stop_identity(stop)
            if key not in seen:
                seen.add(key)
                matches.append(stop)
            break
    for stop in retained_candidate_stop_matches(actor_catalog, retention_specs):
        key = stop_identity(stop)
        if key not in seen:
            seen.add(key)
            matches.append(stop)
    for stop in retained_fallback_stop_matches(retention_specs):
        key = stop_identity(stop)
        if key not in seen:
            seen.add(key)
            matches.append(stop)
    return matches


def build_adventure_stops(actor_catalog, starts_entry, max_stops, retention_specs=None):
    stops = actor_catalog.get("topActorCells", [])
    named = [stop for stop in stops if clean_cell_label(stop.get("cell", {})) != "worldspace actor cluster"]
    startish = [stop for stop in named if "start_area" in stop.get("labels", [])]
    selected = []
    seen = set()
    for pool in (startish, named, stops):
        for stop in sorted(pool, key=lambda item: (len(item.get("labels", [])), item.get("actorCount", 0)), reverse=True):
            key = clean_cell_label(stop.get("cell", {})).lower()
            if key in seen:
                continue
            seen.add(key)
            selected.append(stop)
            if len(selected) >= max_stops:
                break
        if len(selected) >= max_stops:
            break

    retained = retained_stop_matches(actor_catalog, stops, retention_specs)
    retained_keys = {stop_identity(stop) for stop in retained}
    selected_keys = {stop_identity(stop) for stop in selected}
    for stop in retained:
        key = stop_identity(stop)
        if key in selected_keys:
            continue
        selected.append(stop)
        selected_keys.add(key)

    while len(selected) > max_stops:
        removable_index = None
        for index in range(len(selected) - 1, -1, -1):
            if stop_identity(selected[index]) not in retained_keys:
                removable_index = index
                break
        if removable_index is None:
            break
        del selected[removable_index]

    output = [compact_stop(stop) for stop in selected]
    if starts_entry:
        output.insert(
            0,
            {
                "label": starts_entry.get("label") or starts_entry.get("startCell") or "configured start",
                "cell": {
                    "editorId": starts_entry.get("startCell", ""),
                    "openmwId": starts_entry.get("startCell", ""),
                    "isExterior": None,
                    "grid": ((starts_entry.get("anchor") or {}).get("exteriorLocation") or {}).get("grid"),
                },
                "labels": ["configured_start"],
                "actorCount": None,
                "concreteActorCount": None,
                "leveledActorCount": None,
                "center": (starts_entry.get("anchor") or {}).get("position"),
                "castPreview": [],
            },
        )
    return output


def world_status(world, actor_catalog_path):
    if world.get("installStatus") != "ready":
        return "not-ready-local-install"
    if not actor_catalog_path:
        return "needs-actor-cast-mine"
    return "actor-placement-cataloged"


def renderer_status(world_id):
    if world_id == "morrowind":
        return "upstream-openmw-runtime"
    if world_id == "skyrim_vr":
        return "native-actor-proof-started"
    if world_id == "starfield":
        return "metadata-mined-renderer-research"
    return "native-actor-proof-needed"


def compatibility_notes(world_id):
    notes = {
        "morrowind": [
            "This is the native OpenMW path: CELL streaming, actors, sky, and normal world startup already exist.",
            "Use it as the behavioral baseline for how a world should feel when it is not being treated as a detached proof cell.",
        ],
        "oblivion": [
            "TES4-family data is mined, but actor rendering still needs native body/race/skeleton proof comparable to the current Skyrim work.",
            "Exterior proof must load an active grid neighborhood and sky/weather rather than isolated city shell cells.",
        ],
        "fallout3": [
            "Expected to share much of the New Vegas path, but needs its own archive/material/NIF and actor construction proofs.",
            "Megaton/Vault 101 actor placements are mined; the next step is native pixels for Wadsworth, Moira, children, raiders, robots, and creatures.",
        ],
        "fallout_new_vegas": [
            "This is the farthest local ESM4 Fallout path and should be treated as the template for Fallout 3.",
            "Goodsprings/Primm/Novac actor placements are mined; native actors, sky, terrain, and animated set pieces still need telemetry-backed proof.",
        ],
        "skyrim_vr": [
            "Native actor proof has started: body/clothes/head/hair can hit pixels, with face surface/eye/mouth work still incomplete.",
            "The current proof is not enough; it needs the same placement-driven sweep across Riverwood, Helgen, guards, horses, wolves, spiders, and dragons.",
        ],
        "fallout4_vr": [
            "FO4 VR data is mined, including Codsworth/Sanctuary, children, raiders, robots, dogs, radroaches, and deathclaw targets.",
            "Renderer work still needs FO4 BA2/material/body/skeleton proof before it behaves like FNV.",
        ],
        "starfield": [
            "Starfield actor placements are mined from local data, but this is renderer research rather than a proven OpenMW walking world yet.",
            "Creation Engine 2 materials, meshes, terrain/planet data, and actor construction need a separate proof ladder.",
        ],
    }
    return notes.get(world_id, ["No local proof notes yet."])


def find_actor_catalog(cells_dir, world_id):
    candidates = [
        cells_dir / f"{world_id}.actor-cast.esm3-mined.json",
        cells_dir / f"{world_id}.actor-cast.esm4-mined.json",
    ]
    for path in candidates:
        if path.exists():
            return path
    return None


def build_world_entry(world, actor_catalog, actor_catalog_path, starts_entry, max_targets, max_stops, retention_specs=None):
    world_id = world.get("id")
    entry = {
        "worldId": world_id,
        "displayName": world.get("displayName", world_id),
        "supportTier": world.get("supportTier", ""),
        "installStatus": world.get("installStatus", ""),
        "status": world_status(world, actor_catalog_path),
        "rendererStatus": renderer_status(world_id),
        "assetPolicy": "Public-safe metadata only; no retail meshes, textures, archives, screenshots, logs, dumps, or local install paths.",
        "compatibilityNotes": compatibility_notes(world_id),
    }
    if not actor_catalog:
        entry["counts"] = {}
        entry["adventureStops"] = []
        entry["representativeActorKinds"] = []
        entry["coverageGaps"] = [
            {
                "kind": "actor-cast",
                "status": "not-mined",
                "note": "No local actor cast catalog is available for this world in catalog/cells.",
            }
        ]
        return entry

    categories, gaps = build_representative_targets(world_id, actor_catalog, max_targets)
    counts = actor_catalog.get("counts", {})
    entry.update(
        {
            "primaryContent": actor_catalog.get("primaryContent", ""),
            "counts": counts,
            "vanillaPresence": {
                "placedActorRefsMined": counts.get("actorPlacements"),
                "actorCellsMined": counts.get("actorCells"),
                "nativeModelProof": renderer_status(world_id),
                "aiPackagesSchedulesCombatDialogue": "not-proofed-in-this-pass",
                "animationState": "not-proofed-in-this-pass",
            },
            "worldContinuityPlan": {
                "cellMetadataIsMiningIndex": True,
                "viewerTarget": "Launch the authored profile through OpenMW and let the engine stream connected exterior/interior cells and populate actors from game data.",
                "validationRule": "Mined cells and actor positions are audit/index metadata only; do not build detached proof cells, stage actors, or drive placement from coordinates.",
            },
            "configuredStart": {
                "label": starts_entry.get("label", "") if starts_entry else "",
                "startCell": starts_entry.get("startCell", "") if starts_entry else "",
            },
            "adventureStops": build_adventure_stops(actor_catalog, starts_entry, max_stops, retention_specs),
            "representativeActorKinds": categories,
            "coverageGaps": gaps
            + [
                {
                    "kind": "ai-and-animation",
                    "status": "not-proofed",
                    "note": "This catalog proves authored placement metadata. A later render pass must prove native model pixels, then idle/schedule/animation behavior.",
                }
            ],
        }
    )
    return entry


def main():
    parser = argparse.ArgumentParser(description="Build a public-safe all-world adventure/actor proof catalog.")
    parser.add_argument("--worlds-local", default="catalog/worlds.local.json")
    parser.add_argument("--starts", default="catalog/flat-world-proof-starts.json")
    parser.add_argument("--cells-dir", default="catalog/cells")
    parser.add_argument("--out", default="catalog/adventure-actor-catalog.json")
    parser.add_argument("--retained-stops", default="catalog/adventure-actor-retained-stops.json")
    parser.add_argument("--max-targets", type=int, default=3)
    parser.add_argument("--max-stops", type=int, default=10)
    args = parser.parse_args()

    worlds_local = load_json(Path(args.worlds_local))
    starts_path = Path(args.starts)
    starts = load_json(starts_path).get("worlds", {}) if starts_path.exists() else {}
    retained_stops_path = Path(args.retained_stops)
    retained_stops = load_json(retained_stops_path).get("worlds", {}) if retained_stops_path.exists() else {}
    cells_dir = Path(args.cells_dir)
    worlds_by_id = {world.get("id"): world for world in worlds_local.get("worlds", [])}

    entries = []
    for world_id in WORLD_ORDER:
        world = worlds_by_id.get(world_id)
        if not world:
            continue
        actor_catalog_path = find_actor_catalog(cells_dir, world_id)
        actor_catalog = load_json(actor_catalog_path) if actor_catalog_path else None
        entries.append(
            build_world_entry(
                world,
                actor_catalog,
                actor_catalog_path,
                starts.get(world_id),
                args.max_targets,
                args.max_stops,
                retained_stops.get(world_id, []),
            )
        )

    output = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "scope": "Local Bethesda 3D worlds tracked by catalog/worlds.local.json. Classic 2D Fallout titles are intentionally out of scope for this OpenMW world-viewer pass.",
        "assetPolicy": "Public-safe metadata only; no retail assets, screenshots, logs, crash dumps, or local install paths.",
        "proofGoal": "For each local world, know where authored actors are, pick representative people/creatures/robots/monsters to validate, and prove them only through a real OpenMW profile load where the engine streams cells and places actors from game data.",
        "worlds": entries,
    }
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2), encoding="ascii")
    print(json.dumps({"written": str(out_path), "worlds": len(entries)}, indent=2))


if __name__ == "__main__":
    main()
