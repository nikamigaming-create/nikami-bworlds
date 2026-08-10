#!/usr/bin/env python3
"""Collect authored NIF and LAND texture dependencies from a sharded ring."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def materialize(index: dict, project_root: Path) -> dict:
    shard = str(index.get("shard", ""))
    if not shard:
        return index
    if not shard.startswith("res://"):
        raise RuntimeError(f"unsupported cell shard path: {shard}")
    path = project_root / shard.removeprefix("res://")
    if not path.is_file():
        raise RuntimeError(f"missing cell shard: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ring", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--radius", type=int, default=2)
    parser.add_argument("--all-models", action="store_true")
    args = parser.parse_args()
    if args.radius < 0:
        raise RuntimeError("radius must be nonnegative")
    ring = json.loads(args.ring.read_text(encoding="utf-8"))
    project_root = args.ring.resolve().parents[2]
    center_x, center_y = (int(value) for value in ring["center_grid"][:2])
    # Bethesda paths are case-insensitive. Preserve one authored spelling but
    # deduplicate by canonical lowercase path so coverage denominators do not
    # count the same Windows/BSA entry multiple times.
    models: dict[str, str] = {}
    land_textures: dict[str, str] = {}
    cells = [*ring.get("cells", []), *ring.get("interiors", [])]
    for index in cells:
        cell = materialize(index, project_root)
        terrain = cell.get("terrain")
        if isinstance(terrain, dict):
            for layer in [*terrain.get("baseTextures", []), *terrain.get("alphaTextures", [])]:
                if not isinstance(layer, dict):
                    continue
                diffuse = str(layer.get("diffuse", "")).strip().replace("/", "\\")
                if diffuse:
                    resolved = diffuse if diffuse.lower().startswith("textures\\") else "textures\\" + diffuse
                    land_textures.setdefault(resolved.lower(), resolved)
        grid = cell.get("grid")
        include_models = (
            args.all_models
            or
            not isinstance(grid, list)
            or len(grid) < 2
            or bool(cell.get("route_detail", False))
            or max(abs(int(grid[0]) - center_x), abs(int(grid[1]) - center_y)) <= args.radius
        )
        if not include_models:
            continue
        for placement in cell.get("placements", []):
            if not isinstance(placement, dict):
                continue
            model = str(placement.get("model", "")).strip()
            if model.lower().endswith(".nif"):
                canonical_model = model.replace("/", "\\").lower()
                models.setdefault(canonical_model, model)
    result = {
        "schema": "opennv-cell-asset-inventory/v1",
        "sourceRing": str(args.ring.resolve()),
        "cellCount": len(cells),
        "radius": args.radius,
        "allModels": args.all_models,
        "landTextures": sorted(land_textures.values(), key=str.lower),
        "models": sorted(models.values(), key=str.lower),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        f"OPENNV_CELL_ASSET_INVENTORY cells={len(cells)} models={len(models)} "
        f"land_textures={len(land_textures)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
