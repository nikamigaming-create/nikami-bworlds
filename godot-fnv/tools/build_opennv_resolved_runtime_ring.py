#!/usr/bin/env python3
"""Rebuild a streamed Godot route from the resolved OpenNV semantic database.

The old route was parsed from FalloutNV.esm alone.  This compiler retains its
curated exterior footprint, expands the reachable door graph, and replaces all
placements/cells with winning records from the complete save load order.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict, deque
from pathlib import Path
from typing import Any


REC_INITIALLY_DISABLED = 0x800


def compact_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")), encoding="utf-8")


def canonical(value: object) -> str:
    if value is None or value == "":
        return ""
    return f"0x{int(str(value), 16):x}"


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return result or "actor"


def shard_reference(shard_path: Path, project_root: Path) -> str:
    """Use res:// for project data and absolute paths for external stream data."""
    try:
        relative = shard_path.relative_to(project_root)
    except ValueError:
        return shard_path.as_posix()
    return "res://" + relative.as_posix()


def convert_placement(
    row: dict[str, Any], bases: dict[str, dict[str, Any]], door_cells: dict[str, str],
    actor_blueprints: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    base_id = canonical(row.get("base"))
    base = bases.get(base_id, {})
    dest_door = canonical(row.get("destDoor"))
    result: dict[str, Any] = {
        "form_id": canonical(row["id"]),
        "type": row.get("type", ""),
        "base_form_id": base_id,
        "base_type": row.get("baseType", base.get("type", "")),
        "base_editor_id": base.get("editorId", ""),
        "base_full_name": base.get("fullName", ""),
        "model": base.get("model", ""),
        "position": row.get("pos", [0.0, 0.0, 0.0]),
        "rotation_radians": row.get("rot", [0.0, 0.0, 0.0]),
        "scale": float(row.get("scale", 1.0)),
        "destination_door": dest_door or None,
        "destination_position": row.get("destPos"),
        "destination_rotation_radians": row.get("destRot"),
        "locked": bool(row.get("isLocked", False)),
        "lock_level": int(row.get("lockLevel", 0)),
        "record_flags": int(row.get("recordFlags", 0)),
        "enable_parent": canonical(row.get("enableParent")) or None,
        "enable_parent_flags": int(row.get("enableParentFlags", 0)),
        "default_enabled": not bool(int(row.get("recordFlags", 0)) & REC_INITIALLY_DISABLED),
        "source_plugin": row.get("sourcePlugin", ""),
        "source_index": int(row.get("sourceIndex", 0)),
        "looping_sound": canonical(base.get("loopingSound")) or None,
        "activation_sound": canonical(base.get("activationSound")) or None,
        "open_sound": canonical(base.get("openSound")) or None,
        "close_sound": canonical(base.get("closeSound")) or None,
        "loop_sound": canonical(base.get("loopSound")) or None,
        "linked_reference": canonical(row.get("linkedReference")) or None,
        "patrol_idle_seconds": float(row.get("patrolIdleSeconds", 0.0) or 0.0),
        "patrol_idle_script_marker": bool(row.get("patrolIdleScriptMarker", False)),
    }
    if result["base_type"] in ("NPC_", "CREA"):
        blueprint = actor_blueprints.get(base_id, {})
        result["packages"] = [
            canonical(value) for value in blueprint.get("packages", base.get("packages", [])) if value
        ]
        result["script"] = canonical(blueprint.get("script", base.get("script"))) or None
        result["actor_flags"] = int(base.get("actorFlags", 0))
        result["base_template"] = canonical(base.get("baseTemplate")) or None
        result["template_flags"] = int(base.get("templateFlags", 0))
    elif result["base_type"] == "CONT":
        result["inventory"] = [
            {"item": canonical(entry.get("item")), "count": int(entry.get("count", 0))}
            for entry in base.get("inventory", []) if entry.get("item") and int(entry.get("count", 0)) != 0
        ]
    if dest_door:
        result["destination_cell"] = door_cells.get(dest_door, "")
    return result


def center_and_origin(placements: list[dict[str, Any]]) -> tuple[list[float], list[float]]:
    if not placements:
        return [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]
    origin_row = next((row for row in placements if row.get("base_type") == "DOOR"), placements[0])
    origin = [float(v) for v in origin_row["position"]]
    points = [row["position"] for row in placements]
    center = [(min(point[axis] for point in points) + max(point[axis] for point in points)) * 0.5 for axis in range(3)]
    return origin, center


def build(
    template_path: Path,
    semantic_dir: Path,
    output_path: Path,
    output_cells_dir: Path,
    all_cells: bool = False,
    actor_roster_output: Path | None = None,
) -> dict[str, Any]:
    template = json.loads(template_path.read_text(encoding="utf-8"))
    semantic_manifest_path = semantic_dir / "manifest.json"
    semantic_manifest = json.loads(semantic_manifest_path.read_text(encoding="utf-8"))
    cells_document = json.loads((semantic_dir / "cells.json").read_text(encoding="utf-8"))
    cells = {canonical(row["id"]): row for row in cells_document["cells"]}
    bases_document = json.loads((semantic_dir / "placement-bases.json").read_text(encoding="utf-8"))
    bases = {canonical(row["id"]): row for row in bases_document["records"]}
    actor_blueprints_document = json.loads((semantic_dir / "actor-blueprints.json").read_text(encoding="utf-8"))
    if actor_blueprints_document.get("status") != "pass":
        raise RuntimeError("actor blueprint database failed validation")
    actor_blueprints = {
        canonical(row["id"]): row for row in actor_blueprints_document.get("blueprints", [])
    }

    initial_exteriors = {canonical(row["form_id"]) for row in template.get("cells", [])}
    selected_cells = set(cells) if all_cells else set(initial_exteriors)
    if not all_cells:
        selected_cells.update(canonical(row["form_id"]) for row in template.get("interiors", []))
    door_by_id: dict[str, dict[str, Any]] = {}
    doors_by_cell: dict[str, list[dict[str, Any]]] = defaultdict(list)
    placement_shards = sorted((semantic_dir / "placements").glob("*.json"))
    if len(placement_shards) != 256:
        raise RuntimeError(f"expected 256 placement shards, found {len(placement_shards)}")
    for shard_path in placement_shards:
        for row in json.loads(shard_path.read_text(encoding="utf-8"))["placements"]:
            if row.get("baseType") != "DOOR":
                continue
            ref_id = canonical(row["id"])
            parent = canonical(row.get("spatialCell", row.get("parentCell")))
            door_by_id[ref_id] = row
            doors_by_cell[parent].append(row)
    door_cells = {
        ref_id: canonical(row.get("spatialCell", row.get("parentCell")))
        for ref_id, row in door_by_id.items()
    }

    # Traverse only through load-door edges. This adds every room reachable
    # from the curated footprint without spreading through adjacent exterior
    # LAND cells merely because their grid coordinates touch.
    if not all_cells:
        queue = deque(sorted(selected_cells))
        while queue:
            cell_id = queue.popleft()
            for door in doors_by_cell.get(cell_id, []):
                destination = door_cells.get(canonical(door.get("destDoor")), "")
                if not destination or destination in selected_cells or destination not in cells:
                    continue
                selected_cells.add(destination)
                queue.append(destination)

    placements_by_cell: dict[str, list[dict[str, Any]]] = defaultdict(list)
    source_counts = Counter()
    type_counts = Counter()
    for shard_path in placement_shards:
        for row in json.loads(shard_path.read_text(encoding="utf-8"))["placements"]:
            parent = canonical(row.get("spatialCell", row.get("parentCell")))
            if parent not in selected_cells:
                continue
            converted = convert_placement(row, bases, door_cells, actor_blueprints)
            placements_by_cell[parent].append(converted)
            source_counts[converted["source_plugin"]] += 1
            type_counts[converted["type"]] += 1
    for rows in placements_by_cell.values():
        rows.sort(key=lambda row: int(row["form_id"], 16))

    if actor_roster_output is not None:
        actor_targets: list[dict[str, Any]] = []
        for cell_id, rows in placements_by_cell.items():
            cell = cells[cell_id]
            for placement in rows:
                if placement.get("base_type") not in ("NPC_", "CREA") or not placement.get("default_enabled", True):
                    continue
                reference = int(placement["form_id"], 16)
                label = placement.get("base_editor_id") or placement.get("base_full_name") or placement["base_type"]
                actor_targets.append({
                    "id": f"{slug(str(label))}-{reference:08x}",
                    "category": "route-humanoid" if placement["base_type"] == "NPC_" else "route-creature",
                    "authoredRef": f"0x{reference:08x}",
                    "base": f"0x{int(placement['base_form_id'], 16):08x}",
                    "enableParent": placement.get("enable_parent"),
                    "world": canonical(cell.get("parentWorld")) or None,
                    "cell": cell_id,
                    "name": placement.get("base_full_name", ""),
                })
        actor_targets.sort(key=lambda row: int(row["authoredRef"], 16))
        compact_json(actor_roster_output, {
            "schema": "nikami-fnv-actor-roster/v1",
            "source_ring": str(output_path),
            "targetCount": len(actor_targets),
            "selection": {"allCells": all_cells, "cellCount": len(selected_cells), "defaultEnabled": True},
            "targets": actor_targets,
        })

    template_exteriors = {canonical(row["form_id"]): row for row in template.get("cells", [])}
    output_cells: list[dict[str, Any]] = []
    output_interiors: list[dict[str, Any]] = []
    missing_cells: list[str] = []
    missing_door_endpoints: list[str] = []
    exterior_world_counts: Counter[str] = Counter()
    for cell_id in sorted(selected_cells, key=lambda value: int(value, 16)):
        cell = cells.get(cell_id)
        if cell is None:
            missing_cells.append(cell_id)
            continue
        rows = placements_by_cell.get(cell_id, [])
        for row in rows:
            if row.get("destination_door") and not row.get("destination_cell"):
                missing_door_endpoints.append(row["form_id"])
        is_exterior = bool(cell.get("isExterior", False))
        filename = f"{'exterior' if is_exterior else 'interior'}-{cell_id[2:]}.json"
        shard_resource = shard_reference(output_cells_dir / filename, output_path.parents[2])
        if is_exterior:
            template_row = template_exteriors.get(cell_id, {})
            grid = [int(cell.get("x", 0)), int(cell.get("y", 0))]
            exterior_world_counts[canonical(cell.get("parentWorld"))] += 1
            terrain = cell.get("land")
            shard = {
                "form_id": cell_id,
                "grid": grid,
                "source_grid": grid,
                "world_form_id": canonical(cell.get("parentWorld")),
                "route_detail": bool(template_row.get("route_detail", False)),
                "atlas_rotation_radians": float(template_row.get("atlas_rotation_radians", 0.0)),
                "atlas_translation_units": template_row.get("atlas_translation_units", [0.0, 0.0, 0.0]),
                "editor_id": cell.get("editorId", ""),
                "full_name": cell.get("fullName", ""),
                "placements": rows,
                "terrain": terrain,
            }
            compact_json(output_cells_dir / filename, shard)
            output_cells.append({key: value for key, value in shard.items() if key not in ("placements", "terrain")} | {
                "shard": shard_resource, "has_terrain": terrain is not None,
            })
        else:
            origin, center = center_and_origin(rows)
            shard = {
                "form_id": cell_id,
                "editor_id": cell.get("editorId", ""),
                "full_name": cell.get("fullName", ""),
                "placements": rows,
            }
            compact_json(output_cells_dir / filename, shard)
            output_interiors.append({
                "form_id": cell_id,
                "editor_id": cell.get("editorId", ""),
                "full_name": cell.get("fullName", ""),
                "shard": shard_resource,
                "source_origin": origin,
                "source_center": center,
            })

    output_cells.sort(key=lambda row: (row["grid"][0], row["grid"][1], int(row["form_id"], 16)))
    output_interiors.sort(key=lambda row: int(row["form_id"], 16))
    result = {key: value for key, value in template.items() if key not in ("cells", "interiors", "counts", "schema")}
    result.update({
        "schema": "opennv-resolved-runtime-ring/v1",
        "semantic_manifest_sha256": hashlib.sha256(semantic_manifest_path.read_bytes()).hexdigest(),
        "load_order_sha256": semantic_manifest["load_order_sha256"],
        "cells": output_cells,
        "interiors": output_interiors,
        "counts": {
            "templateExteriorCells": len(initial_exteriors),
            "allCells": all_cells,
            "selectedCells": len(selected_cells),
            "exteriorCells": len(output_cells),
            "interiorCells": len(output_interiors),
            "exteriorWorldspaces": len(exterior_world_counts),
            "byExteriorWorldspace": dict(sorted(exterior_world_counts.items())),
            "placements": sum(len(rows) for rows in placements_by_cell.values()),
            "actors": type_counts["ACHR"],
            "creatures": type_counts["ACRE"],
            "doors": sum(1 for rows in placements_by_cell.values() for row in rows if row.get("base_type") == "DOOR"),
            "missingCells": len(missing_cells),
            "missingDoorEndpoints": len(missing_door_endpoints),
            "byPlacementType": dict(sorted(type_counts.items())),
            "bySourcePlugin": dict(sorted(source_counts.items())),
        },
        "failures": {"missingCells": missing_cells, "missingDoorEndpoints": missing_door_endpoints},
    })
    compact_json(output_path, result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--semantic-db", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--output-cells-dir", type=Path, required=True)
    parser.add_argument("--all-cells", action="store_true")
    parser.add_argument("--actor-roster-output", type=Path)
    args = parser.parse_args()
    result = build(
        args.template.resolve(), args.semantic_db.resolve(), args.output.resolve(),
        args.output_cells_dir.resolve(), all_cells=args.all_cells,
        actor_roster_output=args.actor_roster_output.resolve() if args.actor_roster_output else None)
    if result["counts"]["missingCells"] or result["counts"]["missingDoorEndpoints"]:
        raise SystemExit("resolved runtime ring failed closed: " + json.dumps(result["counts"], sort_keys=True))
    print("OPENNV_RESOLVED_RUNTIME_RING " + json.dumps(result["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
