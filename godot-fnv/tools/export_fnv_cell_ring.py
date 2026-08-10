#!/usr/bin/env python3
"""Export a save-centered, engine-neutral FNV exterior cell ring."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
from pathlib import Path


def load_catalog_class(repo_root: Path):
    source = repo_root / "scripts" / "export_esm4_catalog.py"
    spec = importlib.util.spec_from_file_location("nikami_export_esm4_catalog", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load catalog decoder: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.ESM4Catalog


def canonical_asset_path(value: str) -> str:
    return value.replace("/", "\\").lstrip("\\").lower()


def distance_to_segment(point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]) -> float:
    dx, dy = end[0] - start[0], end[1] - start[1]
    length_squared = dx * dx + dy * dy
    if length_squared == 0:
        return math.dist(point, start)
    amount = max(0.0, min(1.0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length_squared))
    return math.dist(point, (start[0] + dx * amount, start[1] + dy * amount))


def transform_position(position: list[float], rotation: float, translation: list[float]) -> list[float]:
    cosine, sine = math.cos(rotation), math.sin(rotation)
    x, y, z = (float(value) for value in position)
    return [
        cosine * x - sine * y + float(translation[0]),
        sine * x + cosine * y + float(translation[1]),
        z + float(translation[2]),
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--esm", type=Path, required=True)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--radius", type=int, default=4)
    parser.add_argument("--detail-radius", type=int, default=None)
    parser.add_argument("--corridor-end-grid", type=int, nargs=2)
    parser.add_argument("--corridor-route", type=Path)
    parser.add_argument("--corridor-width", type=float, default=2.0)
    parser.add_argument("--atlas", type=Path)
    parser.add_argument("--atlas-land-radius", type=int, default=8)
    parser.add_argument("--interiors", choices=("all", "primary-start"), default="all")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.radius < 0:
        raise SystemExit("radius must be non-negative")
    detail_radius = args.radius if args.detail_radius is None else args.detail_radius
    if detail_radius < 0 or detail_radius > args.radius:
        raise SystemExit("detail-radius must be between zero and radius")

    repo_root = Path(__file__).resolve().parents[2]
    bootstrap = json.loads(args.bootstrap.read_text(encoding="utf-8"))
    world_id = str(bootstrap["world"]["form_id"]).lower()
    world_value = int(world_id, 16)
    center_x, center_y = (int(value) for value in bootstrap["world"]["cell_grid"])

    world_transforms: dict[int, tuple[float, list[float]]] = {world_value: (0.0, [0.0, 0.0, 0.0])}
    if args.atlas:
        atlas = json.loads(args.atlas.read_text(encoding="utf-8"))
        for world in atlas.get("worldspaces", []):
            world_transforms[int(world["form_id"], 16)] = (
                float(world.get("rotation_radians", 0.0)),
                [float(value) for value in world.get("translation_units", [0.0, 0.0, 0.0])],
            )

    corridor_start = (float(center_x), float(center_y))
    corridor_end = tuple(float(value) for value in args.corridor_end_grid) if args.corridor_end_grid else None
    corridor_points: list[tuple[float, float]] = [corridor_start]
    if args.corridor_route:
        route = json.loads(args.corridor_route.read_text(encoding="utf-8"))
        corridor_points.extend(
            (float(row["position"][0]) / 4096.0, float(row["position"][1]) / 4096.0)
            for row in route.get("waypoints", [])
        )
    elif corridor_end is not None:
        corridor_points.append(corridor_end)

    def is_primary_detail(x: int, y: int) -> bool:
        if max(abs(x - center_x), abs(y - center_y)) <= detail_radius:
            return True
        return len(corridor_points) >= 2 and any(
            distance_to_segment((x, y), start, end) <= args.corridor_width
            for start, end in zip(corridor_points, corridor_points[1:])
        )

    catalog_type = load_catalog_class(repo_root)
    catalog = catalog_type(args.esm, mod_index=0, terms=[])
    catalog.parse()

    placements_by_id = {str(row["id"]).lower(): row for row in catalog.placements}

    def placement_default_enabled(placement: dict, visiting: set[str] | None = None) -> bool:
        """Resolve the ESM's initial enable state without inventing quest state.

        Bethesda keeps mutually exclusive world variants in the same CELL and
        selects them with the Initially Disabled record flag and XESP enable
        parents. Exporting every physical record stacked quest replacements,
        duplicate actors, blocked doors, and alternate road/building pieces.
        """
        flags = int(placement.get("recordFlags", 0))
        if flags & 0x20 or flags & 0x800:  # Deleted, Initially Disabled
            return False
        parent_id = str(placement.get("enableParent") or "").lower()
        if not parent_id:
            return True
        visiting = set() if visiting is None else visiting
        placement_id = str(placement.get("id", "")).lower()
        if placement_id in visiting:
            return True
        parent = placements_by_id.get(parent_id)
        if parent is None:
            return True
        visiting.add(placement_id)
        parent_enabled = placement_default_enabled(parent, visiting)
        visiting.remove(placement_id)
        return (not parent_enabled) if int(placement.get("enableParentFlags", 0)) & 1 else parent_enabled

    selected_cells: dict[int, dict] = {}
    for form_id, cell in catalog.cells.items():
        parent_world = cell.get("parentWorld")
        parent_world_value = int(parent_world, 16) if parent_world else 0
        if not cell.get("isExterior") or parent_world_value not in world_transforms:
            continue
        x, y = int(cell.get("x", 0)), int(cell.get("y", 0))
        is_primary = parent_world_value == world_value
        if (is_primary and max(abs(x - center_x), abs(y - center_y)) <= args.radius) or not is_primary:
            atlas_rotation, atlas_translation = world_transforms[parent_world_value]
            atlas_center = transform_position([(x + 0.5) * 4096.0, (y + 0.5) * 4096.0, 0.0], atlas_rotation, atlas_translation)
            selected_cells[form_id] = {
                "form_id": cell["id"],
                "grid": [math.floor(atlas_center[0] / 4096.0), math.floor(atlas_center[1] / 4096.0)],
                "source_grid": [x, y],
                "world_form_id": parent_world.lower(),
                "route_detail": is_primary_detail(x, y) if is_primary else True,
                "atlas_rotation_radians": atlas_rotation,
                "atlas_translation_units": atlas_translation,
                "editor_id": cell.get("editorId", ""),
                "full_name": cell.get("fullName", ""),
                "placements": [],
            }
            if cell.get("land"):
                terrain = dict(cell["land"])
                for texture_group in ("baseTextures", "alphaTextures"):
                    for layer in terrain.get(texture_group, []):
                        texture_id = layer.get("texture")
                        texture_record = catalog.records.get(int(texture_id, 16)) if texture_id else None
                        texture_set_id = texture_record.get("textureSet") if texture_record else None
                        texture_set = catalog.records.get(int(texture_set_id, 16)) if texture_set_id else None
                        layer["diffuse"] = canonical_asset_path(
                            str(
                                texture_record.get("landTexture", "")
                                or (texture_set.get("diffuseTexture", "") if texture_set else "")
                            ) if texture_record else ""
                        )
                selected_cells[form_id]["terrain"] = terrain

    assets: dict[str, dict] = {}
    selected_by_world_grid = {
        (int(cell["world_form_id"], 16), *cell["source_grid"]): cell for cell in selected_cells.values()
    }
    placement_count = 0
    for placement in catalog.placements:
        if not placement_default_enabled(placement):
            continue
        parent = placement.get("parentCell")
        if not parent:
            continue
        cell = selected_cells.get(int(parent, 16))
        # Persistent worldspace references live in a terrainless exterior CELL
        # whose nominal grid is not their spatial cell. Route them by position.
        if cell is not None and "terrain" not in cell and placement.get("pos"):
            px, py = placement["pos"][:2]
            cell = selected_by_world_grid.get((int(cell["world_form_id"], 16), math.floor(px / 4096.0), math.floor(py / 4096.0)))
        if cell is None and placement.get("pos"):
            parent_cell = catalog.cells.get(int(parent, 16))
            parent_world = parent_cell.get("parentWorld") if parent_cell else None
            if parent_cell and parent_cell.get("isExterior") and parent_world and int(parent_world, 16) in world_transforms:
                px, py = placement["pos"][:2]
                cell = selected_by_world_grid.get((int(parent_world, 16), math.floor(px / 4096.0), math.floor(py / 4096.0)))
        if cell is None or not placement.get("pos"):
            continue
        base_text = placement.get("base")
        base = catalog.records.get(int(base_text, 16)) if base_text else None
        if not base:
            continue
        models = base.get("models", [])
        if not models and base.get("model"):
            models = [base["model"]]
        model = canonical_asset_path(str(models[0])) if models else ""
        is_actor = base.get("type") in ("NPC_", "CREA")
        if not model.endswith(".nif") and not is_actor:
            continue
        position = transform_position(placement["pos"], cell["atlas_rotation_radians"], cell["atlas_translation_units"])
        rotation = list(placement.get("rot") or [0.0, 0.0, 0.0])
        rotation[2] = float(rotation[2]) + float(cell["atlas_rotation_radians"])
        record = {
            "form_id": placement["id"],
            "type": placement["type"],
            "base_form_id": base_text,
            "base_type": base.get("type", ""),
            "base_editor_id": base.get("editorId", ""),
            "base_full_name": base.get("fullName", ""),
            "model": model,
            "position": position,
            "rotation_radians": rotation,
            "scale": float(placement.get("scale", 1.0)),
            "destination_door": placement.get("destDoor"),
            "destination_position": placement.get("destPos"),
            "destination_rotation_radians": placement.get("destRot"),
            "locked": bool(placement.get("isLocked", False)),
            "lock_level": int(placement.get("lockLevel", 0)),
            "record_flags": int(placement.get("recordFlags", 0)),
            "enable_parent": placement.get("enableParent"),
            "enable_parent_flags": int(placement.get("enableParentFlags", 0)),
            "default_enabled": True,
        }
        if is_actor:
            record["actor"] = {
                "female": bool(base.get("femaleFlag", False)),
                "race": base.get("race"),
                "base_template": base.get("baseTemplate"),
                "default_outfit": base.get("defaultOutfit"),
                "sleep_outfit": base.get("sleepOutfit"),
                "inventory": base.get("inventory", []),
                "packages": base.get("packages", []),
            }
        cell["placements"].append(record)
        placement_count += 1
        if not model.endswith(".nif"):
            continue
        asset = assets.setdefault(
            model,
            {
                "source_path": model,
                "base_types": [],
                "base_form_ids": [],
                "instances": 0,
            },
        )
        asset["instances"] += 1
        if record["base_type"] not in asset["base_types"]:
            asset["base_types"].append(record["base_type"])
        if base_text not in asset["base_form_ids"]:
            asset["base_form_ids"].append(base_text)

    # Resolve every nearby exterior load door to its real destination CELL and
    # export that CELL up front. Runtime portals can then show and enter the
    # destination without performing content I/O at the threshold.
    connected_interior_ids: set[int] = set()
    for cell in selected_cells.values():
        for record in cell["placements"]:
            destination_door = record.get("destination_door")
            destination = placements_by_id.get(str(destination_door).lower()) if destination_door else None
            destination_parent = destination.get("parentCell") if destination else None
            destination_cell = catalog.cells.get(int(destination_parent, 16)) if destination_parent else None
            if destination_cell is None:
                continue
            record["destination_cell"] = destination_cell["id"]
            if not destination_cell.get("isExterior"):
                source_is_primary_start = (
                    int(cell["world_form_id"], 16) == world_value
                    and max(abs(cell["source_grid"][0] - center_x), abs(cell["source_grid"][1] - center_y)) <= detail_radius
                )
                if args.interiors == "all" or source_is_primary_start:
                    connected_interior_ids.add(int(destination_parent, 16))

    interiors: list[dict] = []
    exported_interior_ids: set[int] = set()
    pending_interior_ids = set(connected_interior_ids)
    # Follow load doors recursively. Many authored buildings contain a lobby,
    # back room, basement, or vault level in a second CELL; exporting only the
    # exterior's first hop produced unresolved doors and visibly wrong layouts.
    while pending_interior_ids:
        interior_id = min(pending_interior_ids)
        pending_interior_ids.remove(interior_id)
        if interior_id in exported_interior_ids:
            continue
        exported_interior_ids.add(interior_id)
        source_cell = catalog.cells[interior_id]
        interior = {
            "form_id": source_cell["id"],
            "editor_id": source_cell.get("editorId", ""),
            "full_name": source_cell.get("fullName", ""),
            "placements": [],
        }
        for placement in catalog.placements:
            if not placement_default_enabled(placement):
                continue
            if not placement.get("parentCell") or int(placement["parentCell"], 16) != interior_id:
                continue
            if not placement.get("pos"):
                continue
            base_text = placement.get("base")
            base = catalog.records.get(int(base_text, 16)) if base_text else None
            if not base:
                continue
            models = base.get("models", [])
            if not models and base.get("model"):
                models = [base["model"]]
            model = canonical_asset_path(str(models[0])) if models else ""
            is_actor = base.get("type") in ("NPC_", "CREA")
            if not model.endswith(".nif") and not is_actor:
                continue
            record = {
                "form_id": placement["id"],
                "type": placement["type"],
                "base_form_id": base_text,
                "base_type": base.get("type", ""),
                "base_editor_id": base.get("editorId", ""),
                "base_full_name": base.get("fullName", ""),
                "model": model,
                "position": placement["pos"],
                "rotation_radians": placement.get("rot") or [0.0, 0.0, 0.0],
                "scale": float(placement.get("scale", 1.0)),
                "destination_door": placement.get("destDoor"),
                "destination_position": placement.get("destPos"),
                "destination_rotation_radians": placement.get("destRot"),
                "locked": bool(placement.get("isLocked", False)),
                "lock_level": int(placement.get("lockLevel", 0)),
                "record_flags": int(placement.get("recordFlags", 0)),
                "enable_parent": placement.get("enableParent"),
                "enable_parent_flags": int(placement.get("enableParentFlags", 0)),
                "default_enabled": True,
            }
            destination_door = record.get("destination_door")
            destination = placements_by_id.get(str(destination_door).lower()) if destination_door else None
            if destination and destination.get("parentCell"):
                record["destination_cell"] = destination["parentCell"]
                linked_id = int(destination["parentCell"], 16)
                linked_cell = catalog.cells.get(linked_id)
                if linked_cell is not None and not linked_cell.get("isExterior") and linked_id not in exported_interior_ids:
                    pending_interior_ids.add(linked_id)
            if is_actor:
                record["actor"] = {
                    "female": bool(base.get("femaleFlag", False)),
                    "race": base.get("race"),
                    "base_template": base.get("baseTemplate"),
                    "default_outfit": base.get("defaultOutfit"),
                    "sleep_outfit": base.get("sleepOutfit"),
                    "inventory": base.get("inventory", []),
                    "packages": base.get("packages", []),
                }
            interior["placements"].append(record)
            placement_count += 1
            if not model.endswith(".nif"):
                continue
            asset = assets.setdefault(model, {
                "source_path": model, "base_types": [], "base_form_ids": [], "instances": 0,
            })
            asset["instances"] += 1
            if record["base_type"] not in asset["base_types"]:
                asset["base_types"].append(record["base_type"])
            if base_text not in asset["base_form_ids"]:
                asset["base_form_ids"].append(base_text)
        interior["placements"].sort(key=lambda row: row["form_id"])
        interiors.append(interior)

    satellite_occupied: dict[int, set[tuple[int, int]]] = {}
    for cell in selected_cells.values():
        parent_world = int(cell["world_form_id"], 16)
        if parent_world != world_value and cell["placements"]:
            satellite_occupied.setdefault(parent_world, set()).add(tuple(cell["source_grid"]))

    def retain_cell(cell: dict) -> bool:
        parent_world = int(cell["world_form_id"], 16)
        if parent_world == world_value:
            return "terrain" in cell or bool(cell["placements"])
        if cell["placements"]:
            return True
        if "terrain" not in cell:
            return False
        x, y = (int(value) for value in cell["source_grid"])
        return any(
            max(abs(x - occupied_x), abs(y - occupied_y)) <= args.atlas_land_radius
            for occupied_x, occupied_y in satellite_occupied.get(parent_world, set())
        )

    cells = sorted(
        (cell for cell in selected_cells.values() if retain_cell(cell)),
        key=lambda row: (row["grid"][1], row["grid"][0]),
    )
    for cell in cells:
        cell["placements"].sort(key=lambda row: row["form_id"])

    # Keep the runtime index small and stream authored CELL payloads from
    # independent shards. Godot's JSON parser is not reliable with the full
    # 32-cell-radius Mojave (terrain plus 200k placements) in one document.
    shard_directory = args.output.parent / f"{args.output.stem}-cells"
    shard_directory.mkdir(parents=True, exist_ok=True)
    project_root = args.output.parent.parent.parent

    def shard_path(kind: str, form_id: str) -> tuple[Path, str]:
        disk = shard_directory / f"{kind}-{form_id.lower().removeprefix('0x')}.json"
        relative = disk.resolve().relative_to(project_root.resolve()).as_posix()
        return disk, f"res://{relative}"

    cell_index: list[dict] = []
    for cell in cells:
        disk, resource = shard_path("exterior", cell["form_id"])
        disk.write_text(json.dumps(cell, separators=(",", ":")), encoding="utf-8")
        cell_index.append({
            key: value for key, value in cell.items()
            if key not in ("terrain", "placements")
        } | {"shard": resource, "has_terrain": "terrain" in cell})

    interior_index: list[dict] = []
    for interior in interiors:
        placements = interior["placements"]
        positions = [row["position"] for row in placements]
        origin = next((row["position"] for row in placements if row.get("base_type") == "DOOR"),
                      positions[0] if positions else [0.0, 0.0, 0.0])
        center = [
            (min(row[axis] for row in positions) + max(row[axis] for row in positions)) * 0.5
            for axis in range(3)
        ] if positions else [0.0, 0.0, 0.0]
        disk, resource = shard_path("interior", interior["form_id"])
        disk.write_text(json.dumps(interior, separators=(",", ":")), encoding="utf-8")
        interior_index.append({
            key: value for key, value in interior.items() if key != "placements"
        } | {"shard": resource, "source_origin": origin, "source_center": center})
    result = {
        "schema": "nikami-fnv-godot-cell-ring/v1",
        "source_esm": str(args.esm.resolve()).replace("\\", "/"),
        "world_form_id": world_id,
        "center_grid": [center_x, center_y],
        "radius_cells": args.radius,
        "detail_radius_cells": detail_radius,
        "corridor_end_grid": list(args.corridor_end_grid) if args.corridor_end_grid else None,
        "corridor_width_cells": args.corridor_width if args.corridor_end_grid else None,
        "atlas_worldspaces": len(world_transforms),
        "cell_size_bethesda_units": 4096,
        "bethesda_units_per_meter": 70.0,
        "cells": cell_index,
        "interiors": interior_index,
        "assets": sorted(assets.values(), key=lambda row: (-row["instances"], row["source_path"])),
        "counts": {
            "cells": len(cells),
            "placements": placement_count,
            "unique_models": len(assets),
            "connected_interiors": len(interiors),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # This is a runtime streaming manifest, not a hand-edited report. Compact
    # JSON keeps the complete exterior placement set from inflating into a
    # multi-hundred-megabyte, whitespace-heavy startup file.
    args.output.write_text(json.dumps(result, separators=(",", ":")), encoding="utf-8")
    print("OPENNV_GODOT_CELL_RING " + json.dumps(result["counts"], sort_keys=True))
    print(f"OPENNV_GODOT_CELL_RING_CENTER world={world_id} grid={center_x},{center_y} radius={args.radius}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
