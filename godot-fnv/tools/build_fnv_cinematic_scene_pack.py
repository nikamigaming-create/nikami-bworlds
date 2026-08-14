#!/usr/bin/env python3
"""Build the compact Goodsprings/Novac/Strip/Vault 21 cinematic ring."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--goodsprings", type=Path, required=True)
    parser.add_argument("--novac", type=Path, required=True)
    parser.add_argument("--atlas", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    goodsprings = load(args.goodsprings)
    novac = load(args.novac)
    atlas = load(args.atlas)

    cells: dict[str, dict] = {}

    def retain(rows: list[dict]) -> None:
        for source in rows:
            cell = dict(source)
            cell["route_detail"] = True
            cells[cell["form_id"].lower()] = cell

    goodsprings_center = tuple(int(value) for value in goodsprings.get("center_grid", [-18, -1]))
    retain(
        [
            cell
            for cell in goodsprings.get("cells", [])
            if max(
                abs(int(cell["grid"][0]) - goodsprings_center[0]),
                abs(int(cell["grid"][1]) - goodsprings_center[1]),
            ) <= 2
        ]
    )
    # Novac's authored town occupies these named cells plus the Dinky cell at
    # grid 6,-8 and its immediate visual neighborhood.
    retain(
        [
            cell
            for cell in novac.get("cells", [])
            if cell.get("editor_id") in ("Novac", "NovacDiner", "NovacHotel")
            or max(abs(int(cell["grid"][0]) - 6), abs(int(cell["grid"][1]) + 8)) <= 1
        ]
    )
    strip_names = {
        "StripUltraLuxe",
        "StripVault21",
        "StripStation",
        "StripLucky38",
        "StripTops",
        "FreesideOldMormonFort",
    }
    retain(
        [
            cell
            for cell in atlas.get("cells", [])
            if cell.get("editor_id") in strip_names
            # The Fort's named subcell owns its actors and clutter, while its
            # enclosing walls and ground are authored in adjacent grid cells.
            or (
                str(cell.get("world_form_id", "")).lower()
                == str(atlas.get("world_form_id", "")).lower()
                and max(abs(int(cell["grid"][0]) + 4), abs(int(cell["grid"][1]) - 26)) <= 1
            )
        ]
    )

    # Retain every authored interior reached by a door in any selected exterior
    # ring.  Dropping the Goodsprings/Novac sets here left valid doors pointing
    # at unstaged cells and made their buildings look like incomplete shells.
    # Runtime isolation changes only the cells' global pocket positions; every
    # placement keeps its original cell-local transform and paired-door link.
    interiors_by_id: dict[str, dict] = {}
    for ring in (goodsprings, novac, atlas):
        for interior in ring.get("interiors", []):
            interiors_by_id[str(interior["form_id"]).lower()] = interior
    interiors = sorted(interiors_by_id.values(), key=lambda row: str(row["form_id"]).lower())
    if not interiors:
        raise SystemExit("expected connected authored interiors")

    # Persistent exterior references are authored under the worldspace's
    # synthetic persistent CELL, then routed into their actual streamed cell by
    # position.  Resolve portal scope against the retained runtime container,
    # not that raw parent id, or walking back outside hides the entire exterior.
    runtime_cell_by_ref: dict[str, str] = {}
    for container in [*cells.values(), *interiors]:
        runtime_cell = str(container["form_id"])
        for placement in container.get("placements", []):
            runtime_cell_by_ref[str(placement.get("form_id", "")).lower()] = runtime_cell
    for container in [*cells.values(), *interiors]:
        for placement in container.get("placements", []):
            destination = str(placement.get("destination_door", "")).lower()
            if destination in runtime_cell_by_ref:
                placement["destination_cell"] = runtime_cell_by_ref[destination]

    assets: dict[str, dict] = {}
    placement_count = 0
    actor_count = 0
    for container in [*cells.values(), *interiors]:
        for placement in container.get("placements", []):
            placement_count += 1
            if "actor" in placement:
                actor_count += 1
            model = str(placement.get("model", ""))
            if not model.lower().endswith(".nif"):
                continue
            row = assets.setdefault(
                model,
                {
                    "source_path": model,
                    "base_types": [],
                    "base_form_ids": [],
                    "instances": 0,
                },
            )
            row["instances"] += 1
            for key, source_key in (("base_types", "base_type"), ("base_form_ids", "base_form_id")):
                value = placement.get(source_key)
                if value and value not in row[key]:
                    row[key].append(value)

    result = {
        "schema": "nikami-fnv-godot-cinematic-scene-pack/v1",
        "world_form_id": goodsprings["world_form_id"],
        "center_grid": goodsprings["center_grid"],
        "radius_cells": 32,
        "detail_radius_cells": 32,
        "cell_size_bethesda_units": 4096,
        "bethesda_units_per_meter": 70.0,
        "cells": sorted(cells.values(), key=lambda row: (row["grid"][1], row["grid"][0])),
        "interiors": interiors,
        "assets": sorted(assets.values(), key=lambda row: (-row["instances"], row["source_path"])),
        "cinematic_scenes": [
            {
                "id": "goodsprings",
                "label": "Goodsprings",
                "start": [-69250.0, 2450.0, 8500.0],
                "end": [-68950.0, 2750.0, 8500.0],
                "look_start": [-67970.1797, 3904.4937, 8475.0],
                "look_end": [-67704.0, 2552.0, 8475.0],
            },
            {
                "id": "novac",
                "label": "Novac",
                "start": [23250.0, -34050.0, 7100.0],
                "end": [23600.0, -33800.0, 7120.0],
                "look_start": [24789.1016, -32500.7852, 7450.0],
                "look_end": [23258.3379, -32546.1152, 7300.0],
            },
            {
                "id": "strip",
                "label": "The Strip",
                # Keep the rail in the open Strip boulevard beside Vault 21;
                # the former Lucky 38 approach crossed an authored building
                # shell. Pan from the hotel frontage toward the skyline.
                "start": [-34250.0, 83500.0, 4750.0],
                "end": [-33750.0, 84250.0, 4750.0],
                "look_start": [-32793.7639, 85445.8125, 5100.0],
                "look_end": [-25888.1356, 93071.5874, 6000.0],
            },
            {
                "id": "vault21",
                "label": "Vault 21",
                "start": [-34000.0, 84000.0, 4505.0],
                "end": [-33650.0, 84400.0, 4505.0],
                "look_start": [-32793.7639, 85445.8125, 4800.0],
                "look_end": [-33221.4974, 84872.3290, 4475.0],
                "door": "0x13bb0b",
                "door_at_seconds": 7.5,
            },
        ],
        "portrait_scenes": [
            {"id": "easy-pete", "label": "Easy Pete / Goodsprings", "actor": "0x104c80", "distance": 1.05, "target_height": 1.45},
            {"id": "arcade-gannon", "label": "Arcade Gannon / Old Mormon Fort", "actor": "0x10d8eb", "distance": 1.05, "target_height": 1.45},
            {"id": "vulpes-inculta", "label": "Vulpes Inculta / The Strip", "actor": "0x131f78", "distance": 1.05, "target_height": 1.45},
            {"id": "victor", "label": "Victor / Goodsprings", "actor": "0x1073e8", "distance": 2.7, "target_height": 1.65},
        ],
        "counts": {
            "cells": len(cells),
            "interiors": len(interiors),
            "placements": placement_count,
            "actors": actor_count,
            "unique_models": len(assets),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print("OPENNV_CINEMATIC_SCENE_PACK " + json.dumps(result["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
