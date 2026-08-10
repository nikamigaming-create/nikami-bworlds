#!/usr/bin/env python3
"""Refresh OpenMW-equivalent BSX collision flags without rewriting OBJ files."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

if not hasattr(time, "clock"):
    time.clock = time.perf_counter  # PyFFI compatibility with Python 3.8+

from pyffi.formats.nif import NifFormat  # type: ignore  # noqa: E402

from convert_fnv_nif_to_obj import diffuse_texture_for_shape, openmw_collision_surfaces


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native-mesh-root", type=Path, required=True)
    parser.add_argument("--converted-root", type=Path, required=True)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=0)
    args = parser.parse_args()
    if args.shard_count < 1 or not 0 <= args.shard_index < args.shard_count:
        parser.error("shard-index must be within shard-count")

    updated = 0
    unchanged = 0
    missing = 0
    rejected: list[str] = []
    colliding = 0
    noncolliding = 0

    nif_paths = sorted(args.native_mesh_root.rglob("*.nif"))
    nif_paths = [
        path for index, path in enumerate(nif_paths)
        if index % args.shard_count == args.shard_index
    ]
    for nif_path in nif_paths:
        relative = nif_path.relative_to(args.native_mesh_root)
        sidecar = args.converted_root / relative.with_suffix(".obj.textures.json")
        if not sidecar.is_file():
            missing += 1
            continue
        try:
            data = NifFormat.Data()
            with nif_path.open("rb") as stream:
                data.read(stream)
            if not data.roots:
                raise ValueError("NIF has no roots")
            geometry = [
                block for block in data.get_global_iterator()
                if isinstance(block, (NifFormat.NiTriShape, NifFormat.NiTriStrips)) and block.data
            ]
            flags, surfaces = openmw_collision_surfaces(data.roots[0], geometry)
            metadata = json.loads(sidecar.read_text(encoding="utf-8"))
            diffuse_textures: list[str] = []
            alpha_surfaces: list[bool] = []
            two_sided_surfaces: list[bool] = []
            render_surfaces: list[bool] = []
            for shape in geometry:
                diffuse = diffuse_texture_for_shape(shape)
                diffuse_textures.append(diffuse)
                alpha_surfaces.append(
                    any(isinstance(prop, NifFormat.NiAlphaProperty) for prop in shape.properties))
                two_sided_surfaces.append(
                    any(isinstance(prop, NifFormat.NiStencilProperty) for prop in shape.properties))
                render_surfaces.append(diffuse.endswith(".dds"))
            desired = {
                "textures": sorted(set(value for value in diffuse_textures if value)),
                "alpha_surfaces": alpha_surfaces,
                "two_sided_surfaces": two_sided_surfaces,
                "render_surfaces": render_surfaces,
                "collision_surfaces": surfaces,
                "collision_mode": "openmw-bsx-render-geometry-v1",
                "bsx_flags": flags,
            }
            if all(metadata.get(key) == value for key, value in desired.items()):
                unchanged += 1
            else:
                metadata.update(desired)
                temporary = sidecar.with_suffix(sidecar.suffix + ".tmp")
                temporary.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
                temporary.replace(sidecar)
                updated += 1
            if any(surfaces):
                colliding += 1
            else:
                noncolliding += 1
        except Exception as exc:  # keep the census complete and fail closed below
            rejected.append(f"{relative.as_posix()}: {exc}")

    report = {
        "schema": "nikami-open-nv-collision-metadata-refresh/v1",
        "shard_count": args.shard_count,
        "shard_index": args.shard_index,
        "requested": len(nif_paths),
        "updated": updated,
        "unchanged": unchanged,
        "missing_sidecars": missing,
        "colliding_models": colliding,
        "noncolliding_models": noncolliding,
        "rejected": rejected,
    }
    print("OPENNV_COLLISION_METADATA " + json.dumps(report, sort_keys=True))
    return 1 if rejected else 0


if __name__ == "__main__":
    raise SystemExit(main())
