#!/usr/bin/env python3
"""Build the exact authored Goodsprings interaction denominator from FalloutNV.esm.

The census stores record metadata only. It does not copy Bethesda asset or script
payloads. Persistent WastelandNV references are admitted by authored position,
which prevents the persistent cell from turning a Goodsprings crawl into a
whole-game crawl.
"""

import argparse
import hashlib
import json
import math
from collections import Counter, defaultdict, deque
from pathlib import Path

from export_esm4_catalog import ESM4Catalog


WASTELAND_NV = 0x000DA726
PERSISTENT_WASTELAND_CELL = 0x000846EA
REGION = {"minX": -20, "maxX": -15, "minY": -5, "maxY": 2}

PICKUP_TYPES = {
    "ALCH",
    "AMMO",
    "ARMO",
    "BOOK",
    "CLOT",
    "INGR",
    "KEYM",
    "MISC",
    "NOTE",
    "WEAP",
}

INTERACTION_TYPES = {
    "DOOR": "door",
    "CONT": "container",
    "ACTI": "activator",
    "TACT": "talking-activator",
    "TERM": "terminal",
    "FURN": "furniture",
    "NPC_": "actor",
    "CREA": "creature",
}

REQUIRED_ANCHORS = {
    0x00104C80: "Easy Pete",
    0x00104E85: "Sunny Smiles",
    0x00104C79: "Chet",
    0x00104C0F: "Doc Mitchell",
    0x0010636F: "Prospector Saloon exterior door",
    0x0010618E: "Prospector Saloon return door",
    0x00109087: "Prospector Saloon radio",
}


def form_int(value):
    return int(value, 16) if value else None


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def position_grid(position):
    if not position or len(position) < 2:
        return None
    return math.floor(position[0] / 4096.0), math.floor(position[1] / 4096.0)


def grid_in_region(grid):
    return grid is not None and REGION["minX"] <= grid[0] <= REGION["maxX"] and REGION["minY"] <= grid[1] <= REGION["maxY"]


def classify(base_type):
    if base_type in INTERACTION_TYPES:
        return INTERACTION_TYPES[base_type]
    if base_type in PICKUP_TYPES:
        return "pickup"
    return None


def is_named_goodsprings_cell(cell):
    editor = cell.get("editorId", "").lower()
    name = cell.get("fullName", "").lower()
    return (
        "goodspring" in editor
        or "goodspring" in name
        or editor.startswith("gsdoc")
        or editor.startswith("gsprospector")
        or editor.startswith("gsgeneral")
        or editor.startswith("gsgas")
        or editor.startswith("gsschool")
        or editor.startswith("gshouse")
    )


def build_census(esm_path, roster_path):
    catalog = ESM4Catalog(esm_path)
    catalog.parse()
    placements = {form_int(row["id"]): row for row in catalog.placements}
    by_cell = defaultdict(list)
    for row in catalog.placements:
        by_cell[form_int(row["parentCell"])].append(row)

    roster = json.loads(roster_path.read_text(encoding="utf-8"))
    roster_refs = {int(row["authoredRef"], 16) for row in roster["targets"]}

    exterior_cells = set()
    interior_cells = set()
    for cell_id, cell in catalog.cells.items():
        if (
            cell.get("isExterior")
            and form_int(cell.get("parentWorld")) == WASTELAND_NV
            and grid_in_region((cell.get("x"), cell.get("y")))
        ):
            exterior_cells.add(cell_id)
        elif not cell.get("isExterior") and is_named_goodsprings_cell(cell):
            interior_cells.add(cell_id)

    scoped_persistent_refs = set()
    for row in by_cell[PERSISTENT_WASTELAND_CELL]:
        ref_id = form_int(row["id"])
        if grid_in_region(position_grid(row.get("pos"))) or ref_id in roster_refs:
            scoped_persistent_refs.add(ref_id)

    for ref_id in roster_refs:
        row = placements.get(ref_id)
        if not row:
            continue
        parent = form_int(row["parentCell"])
        if parent != PERSISTENT_WASTELAND_CELL:
            cell = catalog.cells.get(parent, {})
            (exterior_cells if cell.get("isExterior") else interior_cells).add(parent)

    def included_ref(row):
        parent = form_int(row["parentCell"])
        if parent == PERSISTENT_WASTELAND_CELL:
            return form_int(row["id"]) in scoped_persistent_refs
        return parent in exterior_cells or parent in interior_cells

    # Follow only doors whose source is already in the local spatial/named scope.
    # A destination in the Wasteland persistent cell is an exit, not permission to
    # admit every other persistent reference.
    pending = deque()
    for row in catalog.placements:
        if included_ref(row) and row.get("destDoor"):
            pending.append(form_int(row["destDoor"]))
    visited_destinations = set()
    while pending:
        destination = pending.popleft()
        if destination in visited_destinations:
            continue
        visited_destinations.add(destination)
        target = placements.get(destination)
        if not target:
            continue
        parent = form_int(target["parentCell"])
        if parent == PERSISTENT_WASTELAND_CELL:
            if grid_in_region(position_grid(target.get("pos"))):
                scoped_persistent_refs.add(destination)
            continue
        target_cell = catalog.cells.get(parent, {})
        if target_cell.get("isExterior"):
            if form_int(target_cell.get("parentWorld")) == WASTELAND_NV and grid_in_region((target_cell.get("x"), target_cell.get("y"))):
                exterior_cells.add(parent)
            continue
        if parent not in interior_cells:
            interior_cells.add(parent)
            for nested in by_cell[parent]:
                if nested.get("destDoor"):
                    pending.append(form_int(nested["destDoor"]))

    scoped_rows = []
    scene_type_counts = Counter()
    category_counts = Counter()
    for row in catalog.placements:
        if not included_ref(row):
            continue
        base_id = form_int(row.get("base"))
        base = catalog.records.get(base_id, {})
        base_type = base.get("type", "missing")
        scene_type_counts[base_type] += 1
        category = classify(base_type)
        if category is None:
            continue
        category_counts[category] += 1
        parent_id = form_int(row["parentCell"])
        parent = catalog.cells.get(parent_id, {})
        effective_grid = position_grid(row.get("pos")) if parent_id == PERSISTENT_WASTELAND_CELL else None
        scoped_rows.append(
            {
                "category": category,
                "reference": row["id"],
                "referenceType": row["type"],
                "referenceEditorId": row.get("editorId", ""),
                "recordFlags": row.get("recordFlags", 0),
                "base": row.get("base"),
                "baseType": base_type,
                "baseEditorId": base.get("editorId", ""),
                "name": base.get("fullName", ""),
                "cell": row["parentCell"],
                "cellEditorId": parent.get("editorId", ""),
                "cellName": parent.get("fullName", ""),
                "cellGrid": effective_grid or ([parent.get("x"), parent.get("y")] if parent.get("isExterior") else None),
                "position": row.get("pos"),
                "rotationRadians": row.get("rot"),
                "count": row.get("count", 1),
                "owner": row.get("owner"),
                "global": row.get("global"),
                "factionRank": row.get("factionRank", -1),
                "lock": {
                    "present": row.get("isLocked", False),
                    "level": row.get("lockLevel", 0),
                    "key": row.get("lockKey"),
                    "dataBytes": row.get("lockDataBytes", 0),
                },
                "teleport": {
                    "destinationDoor": row.get("destDoor"),
                    "destinationPosition": row.get("destPos"),
                    "destinationRotationRadians": row.get("destRot"),
                    "flags": row.get("teleportFlags", 0),
                },
                "enableParent": row.get("enableParent"),
                "enableParentFlags": row.get("enableParentFlags", 0),
                "engineCheckpoint": {
                    "load": "pending-runtime-proof",
                    "visible": "pending-runtime-proof",
                    "activate": "pending-runtime-proof",
                    "mutation": "pending-runtime-proof",
                    "saveReload": "pending-runtime-proof",
                },
            }
        )

    scoped_rows.sort(key=lambda row: (int(row["cell"], 16), int(row["reference"], 16)))
    missing_anchors = [f"0x{ref_id:08x} {label}" for ref_id, label in REQUIRED_ANCHORS.items() if ref_id not in placements]
    if missing_anchors:
        raise RuntimeError("missing required FalloutNV.esm anchors: " + ", ".join(missing_anchors))

    cells = []
    for cell_id in sorted(exterior_cells | interior_cells):
        cell = catalog.cells[cell_id]
        cells.append(
            {
                "form": cell["id"],
                "editorId": cell.get("editorId", ""),
                "name": cell.get("fullName", ""),
                "exterior": cell.get("isExterior", False),
                "grid": [cell.get("x"), cell.get("y")] if cell.get("isExterior") else None,
                "authoredReferenceCount": len(by_cell[cell_id]),
            }
        )

    return {
        "schema": "nikami-fnv-goodsprings-interaction-census/v1",
        "source": {
            "file": esm_path.name,
            "bytes": esm_path.stat().st_size,
            "sha256": sha256_file(esm_path),
            "recordCount": len(catalog.records),
            "placementCount": len(catalog.placements),
        },
        "scope": {
            "worldspace": f"0x{WASTELAND_NV:08x}",
            "persistentCell": f"0x{PERSISTENT_WASTELAND_CELL:08x}",
            "exteriorGridBoundsInclusive": REGION,
            "rule": "local WastelandNV exterior cells plus position-filtered persistent references, named/roster Goodsprings interiors, and their authored local teleport-door closure",
            "cellCount": len(cells),
            "persistentReferenceCount": len(scoped_persistent_refs),
            "interactiveReferenceCount": len(scoped_rows),
        },
        "summary": {
            "byCategory": dict(sorted(category_counts.items())),
            "allSceneReferencesByBaseType": dict(sorted(scene_type_counts.items())),
            "runtimeCheckpointCount": len(scoped_rows) * 5,
            "runtimeCheckpointsPassed": 0,
        },
        "cells": cells,
        "references": scoped_rows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esm", required=True, type=Path)
    parser.add_argument("--roster", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if not args.esm.is_file():
        raise SystemExit(f"missing FalloutNV.esm: {args.esm}")
    if not args.roster.is_file():
        raise SystemExit(f"missing Goodsprings roster: {args.roster}")
    result = build_census(args.esm, args.roster)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        f"wrote {args.out} cells={result['scope']['cellCount']} "
        f"references={result['scope']['interactiveReferenceCount']} "
        f"checkpoints={result['summary']['runtimeCheckpointCount']}"
    )


if __name__ == "__main__":
    main()
