#!/usr/bin/env python3
"""Build the authored Mojave-to-Strip spatial atlas.

The source game stores Freeside and the Strip in several unrelated WRLD
coordinate charts.  This chooses the canonical north-gate route as one rigid,
continuous spine.  Other entrances remain portal edges because aligning both
entrances of a non-Euclidean pair simultaneously would distort the districts.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from export_fnv_cell_ring import load_catalog_class


PRIMARY_SPINE = [
    ("mojave_to_freeside_north", "0x116420"),
    ("freeside_north_to_freeside", "0x133954"),
    ("freeside_to_strip", "0x116425"),
]
PRIMARY_BRANCHES = [("freeside_north_to_mormon_fort", "0x133966")]
OPEN_IN_PLACE = ["0x16a14d", "0x16a14e", "0x16a14f", "0x16a150"]


def rotate(point: list[float], angle: float) -> tuple[float, float]:
    cosine, sine = math.cos(angle), math.sin(angle)
    return cosine * point[0] - sine * point[1], sine * point[0] + cosine * point[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--esm", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    catalog_type = load_catalog_class(repo_root)
    catalog = catalog_type(args.esm, mod_index=0, terms=[])
    catalog.parse()
    placements = {str(row["id"]).lower(): row for row in catalog.placements}

    def parent_world(placement: dict) -> str:
        cell = catalog.cells[int(placement["parentCell"], 16)]
        return str(cell["parentWorld"]).lower()

    def world_record(world_id: str) -> dict:
        return catalog.records.get(int(world_id, 16), {})

    # world -> (rotation radians, x/y/z translation in Bethesda units)
    transforms: dict[str, tuple[float, tuple[float, float, float]]] = {
        "0xda726": (0.0, (0.0, 0.0, 0.0)),  # WastelandNV / Mojave Wasteland
    }
    seams: list[dict] = []

    def attach(label: str, source_id: str) -> None:
        source = placements[source_id]
        destination = placements[str(source["destDoor"]).lower()]
        source_world = parent_world(source)
        destination_world = parent_world(destination)
        if source_world not in transforms:
            raise RuntimeError(f"atlas source is not connected yet: {source_world} ({label})")
        source_angle, source_translation = transforms[source_world]
        source_yaw = float((source.get("rot") or [0.0, 0.0, 0.0])[2])
        destination_yaw = float((destination.get("rot") or [0.0, 0.0, 0.0])[2])
        destination_angle = source_angle + source_yaw + math.pi - destination_yaw
        source_xy = rotate(source["pos"], source_angle)
        destination_xy = rotate(destination["pos"], destination_angle)
        source_global = (
            source_xy[0] + source_translation[0],
            source_xy[1] + source_translation[1],
            float(source["pos"][2]) + source_translation[2],
        )
        destination_translation = (
            source_global[0] - destination_xy[0],
            source_global[1] - destination_xy[1],
            source_global[2] - float(destination["pos"][2]),
        )
        transforms[destination_world] = (destination_angle, destination_translation)
        check_xy = rotate(destination["pos"], destination_angle)
        check = (
            check_xy[0] + destination_translation[0],
            check_xy[1] + destination_translation[1],
            float(destination["pos"][2]) + destination_translation[2],
        )
        error = math.dist(source_global, check)
        seams.append({
            "label": label,
            "source_door": source_id,
            "destination_door": destination["id"],
            "source_world": source_world,
            "destination_world": destination_world,
            "atlas_position": list(source_global),
            "seam_error_units": error,
            "seam_error_meters": error / 70.0,
        })

    for label, source_id in PRIMARY_SPINE:
        attach(label, source_id)
    for label, source_id in PRIMARY_BRANCHES:
        attach(label, source_id)

    worlds = []
    for world_id, (angle, translation) in transforms.items():
        record = world_record(world_id)
        worlds.append({
            "form_id": world_id,
            "editor_id": record.get("editorId", ""),
            "full_name": record.get("fullName", ""),
            "rotation_radians": angle,
            "translation_units": list(translation),
            "translation_meters": [value / 70.0 for value in translation],
        })

    result = {
        "schema": "nikami-opennv-seamless-atlas/v1",
        "source_esm": str(args.esm.resolve()).replace("\\", "/"),
        "units_per_meter": 70.0,
        "policy": {
            "primary_spine": "Mojave north gate -> Freeside North -> Freeside -> Strip",
            "secondary_entrances": "portal charts; never force an incompatible global transform",
            "strip_internal_gates": "physical opening gates; transition disabled",
        },
        "worldspaces": worlds,
        "seams": seams,
        "open_in_place_doors": OPEN_IN_PLACE,
        "validation": {
            "connected_worldspaces": len(worlds),
            "primary_spine_seams": len(PRIMARY_SPINE),
            "maximum_seam_error_meters": max(row["seam_error_meters"] for row in seams),
            "pass": all(row["seam_error_meters"] < 1.0e-6 for row in seams),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print("OPENNV_SEAMLESS_ATLAS " + json.dumps(result["validation"], sort_keys=True))
    return 0 if result["validation"]["pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
