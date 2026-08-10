#!/usr/bin/env python3
"""Build a stable authored-reference actor roster from an OpenNV route ring."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return result or "actor"


def materialize_cell(index: dict, project_root: Path) -> dict:
    shard = str(index.get("shard", ""))
    if not shard:
        return index
    path = project_root / shard.removeprefix("res://") if shard.startswith("res://") else Path(shard)
    if not path.is_file():
        raise RuntimeError(f"missing cell shard: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ring", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--exclude-manifest", type=Path, action="append", default=[])
    parser.add_argument(
        "--upgrade-static-manifest",
        type=Path,
        help="Select only ring actors present in this manifest without a skeletal payload.",
    )
    parser.add_argument("--grid-center", help="Optional exterior center as x,y")
    parser.add_argument("--grid-radius", type=int, default=0)
    parser.add_argument("--interior-id", action="append", default=[])
    parser.add_argument("--authored-ref", action="append", default=[])
    args = parser.parse_args()
    ring = json.loads(args.ring.read_text(encoding="utf-8"))
    project_root = args.ring.resolve().parents[2]
    excluded: set[int] = set()
    for manifest_path in args.exclude_manifest:
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        excluded.update(int(str(actor["authored_ref"]), 16) for actor in existing.get("actors", []))
    static_upgrade_refs: set[int] | None = None
    if args.upgrade_static_manifest:
        upgrade_manifest = json.loads(args.upgrade_static_manifest.read_text(encoding="utf-8"))
        static_upgrade_refs = {
            int(str(actor["authored_ref"]), 16)
            for actor in upgrade_manifest.get("actors", [])
            if not str(actor.get("skeletal", "")).strip()
        }
    targets = []
    seen: set[int] = set()
    requested_refs = {int(value, 16) for value in args.authored_ref}
    selected_cells = [*ring.get("cells", []), *ring.get("interiors", [])]
    if args.grid_center:
        center_values = [int(value.strip()) for value in args.grid_center.split(",")]
        if len(center_values) != 2 or args.grid_radius < 0:
            raise RuntimeError("--grid-center requires x,y and a nonnegative --grid-radius")
        center_x, center_y = center_values
        selected_interiors = {int(value, 16) for value in args.interior_id}
        selected_cells = [
            cell
            for cell in selected_cells
            if (
                len(cell.get("grid", [])) >= 2
                and max(abs(int(cell["grid"][0]) - center_x), abs(int(cell["grid"][1]) - center_y))
                <= args.grid_radius
            )
            or int(str(cell.get("form_id", "0")), 16) in selected_interiors
        ]
    for cell_index in selected_cells:
        cell = materialize_cell(cell_index, project_root)
        for placement in cell.get("placements", []):
            if placement.get("base_type") not in ("NPC_", "CREA"):
                continue
            if placement.get("default_enabled") is False:
                continue
            reference = int(placement["form_id"], 16)
            if requested_refs and reference not in requested_refs:
                continue
            if reference in seen or reference in excluded:
                continue
            if static_upgrade_refs is not None and reference not in static_upgrade_refs:
                continue
            seen.add(reference)
            label = placement.get("base_editor_id") or placement.get("base_full_name") or placement["base_type"]
            targets.append(
                {
                    "id": f"{slug(str(label))}-{reference:08x}",
                    "category": "route-humanoid" if placement["base_type"] == "NPC_" else "route-creature",
                    "authoredRef": f"0x{reference:08x}",
                    "base": f"0x{int(placement['base_form_id'], 16):08x}",
                    "enableParent": None,
                    "world": cell.get("world_form_id"),
                    "cell": cell.get("form_id"),
                    "name": placement.get("base_full_name", ""),
                }
            )
    targets.sort(key=lambda row: int(row["authoredRef"], 16))
    found_refs = {int(row["authoredRef"], 16) for row in targets}
    missing_requested = sorted(requested_refs - found_refs)
    if missing_requested:
        raise RuntimeError(
            "requested authored refs were not enabled actor placements in the ring: "
            + ", ".join(f"0x{value:08x}" for value in missing_requested)
        )
    result = {
        "schema": "nikami-fnv-actor-roster/v1",
        "source_ring": str(args.ring.resolve()),
        "targetCount": len(targets),
        "selection": {
            "gridCenter": args.grid_center,
            "gridRadius": args.grid_radius if args.grid_center else None,
            "interiorIds": args.interior_id,
            "authoredRefs": [f"0x{value:08x}" for value in sorted(requested_refs)],
            "cellCount": len(selected_cells),
        },
        "targets": targets,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"OPENNV_ROUTE_ACTOR_ROSTER count={len(targets)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
