#!/usr/bin/env python3
"""Bake authored ESM LAND texture layers into streamable per-cell albedo maps."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def asset_path(root: Path, value: str) -> Path:
    relative = value.replace("\\", "/").lstrip("/")
    if not relative.lower().startswith("textures/"):
        relative = "textures/" + relative
    return root / relative


def tiled_texture(path: Path, size: int, repeats: int) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    tile = image.resize((max(1, size // repeats), max(1, size // repeats)), Image.Resampling.LANCZOS)
    tiled = Image.new("RGB", (size, size))
    for y in range(0, size, tile.height):
        for x in range(0, size, tile.width):
            tiled.paste(tile, (x, y))
    return np.asarray(tiled, dtype=np.float32)


def opacity_image(vertices: list[dict], size: int) -> np.ndarray:
    weights = np.zeros((17, 17), dtype=np.float32)
    for vertex in vertices:
        index = int(vertex.get("index", -1))
        if 0 <= index < 289:
            weights[index // 17, index % 17] = np.clip(float(vertex.get("opacity", 0.0)), 0.0, 1.0)
    source = Image.fromarray(np.uint8(np.round(weights * 255.0)), mode="L")
    return np.asarray(source.resize((size, size), Image.Resampling.BILINEAR), dtype=np.float32)[:, :, None] / 255.0


def bake_cell(terrain: dict, texture_root: Path, size: int, repeats: int) -> Image.Image | None:
    quadrant_size = size // 2
    output = np.zeros((size, size, 3), dtype=np.float32)
    cache: dict[str, np.ndarray] = {}

    def texture(value: str) -> np.ndarray | None:
        if not value:
            return None
        path = asset_path(texture_root, value)
        if not path.is_file():
            return None
        key = str(path).lower()
        if key not in cache:
            cache[key] = tiled_texture(path, quadrant_size, repeats)
        return cache[key]

    bases = {int(row["quadrant"]): row for row in terrain.get("baseTextures", [])}
    overlays: dict[int, list[dict]] = {value: [] for value in range(4)}
    for row in terrain.get("alphaTextures", []):
        overlays.setdefault(int(row.get("quadrant", 0)), []).append(row)

    rendered = False
    for quadrant in range(4):
        base = texture(str(bases.get(quadrant, {}).get("diffuse", "")))
        if base is None:
            continue
        composite = base.copy()
        for layer in sorted(overlays.get(quadrant, []), key=lambda row: int(row.get("layer", 0))):
            pixels = texture(str(layer.get("diffuse", "")))
            if pixels is None:
                continue
            alpha = opacity_image(layer.get("vertices", []), quadrant_size)
            composite = composite * (1.0 - alpha) + pixels * alpha
        x = quadrant_size if quadrant in (1, 3) else 0
        y = quadrant_size if quadrant in (2, 3) else 0
        output[y : y + quadrant_size, x : x + quadrant_size] = composite
        rendered = True
    if not rendered:
        return None
    return Image.fromarray(np.uint8(np.clip(output, 0, 255)), mode="RGB")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ring", type=Path, required=True)
    parser.add_argument("--texture-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--radius", type=int, default=4)
    parser.add_argument("--route-detail", action="store_true")
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--repeats", type=int, default=8)
    args = parser.parse_args()

    ring = json.loads(args.ring.read_text(encoding="utf-8"))
    center_x, center_y = (int(value) for value in ring["center_grid"])
    args.output.mkdir(parents=True, exist_ok=True)
    baked = 0
    missing = 0
    for cell in ring["cells"]:
        if "terrain" not in cell:
            continue
        x, y = (int(value) for value in cell["grid"])
        if (max(abs(x - center_x), abs(y - center_y)) > args.radius
                and not (args.route_detail and bool(cell.get("route_detail", False)))):
            continue
        image = bake_cell(cell["terrain"], args.texture_root, args.size, args.repeats)
        if image is None:
            missing += 1
            continue
        source_x, source_y = (int(value) for value in cell.get("source_grid", cell["grid"]))
        world = str(cell.get("world_form_id", ring.get("world_form_id", "0"))).lower().removeprefix("0x")
        image.save(args.output / f"land_{world}_{source_x}_{source_y}.png", optimize=True)
        baked += 1
    print(
        f"OPENNV_LAND_ALBEDO baked={baked} missing={missing} "
        f"radius={args.radius} route_detail={int(args.route_detail)}"
    )
    # A handful of edge LAND records intentionally inherit/default their base
    # paint and contain no BTXT. The runtime uses its neutral authored-region
    # fallback for those cells; do not reject the complete nearby bake.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
