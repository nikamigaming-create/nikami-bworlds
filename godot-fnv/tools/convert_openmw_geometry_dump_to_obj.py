#!/usr/bin/env python3
"""Fallback OBJ conversion using OpenMW's native NIF reader.

This path is for valid retail NIFs that PyFFI cannot decode. OpenMW emits
world-space geometry, topology, material links and BSX flags; this tool only
performs the project coordinate conversion and writes the normal OBJ cache.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def canonical_texture(value: str) -> str:
    return value.replace("/", "\\").lstrip("\\").lower()


def embedded_diffuse_candidates(nif_path: Path) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for match in re.findall(rb"[A-Za-z0-9_ ./\\-]{4,}\.dds", nif_path.read_bytes(), re.I):
        value = canonical_texture(match.decode("ascii", errors="ignore"))
        stem = Path(value).stem.lower()
        if stem.endswith(("_n", "_m", "_e", "_g", "_sk", "_s")):
            continue
        if value not in seen:
            seen.add(value)
            values.append(value)
    return values


def godot_vertex(value: list[float]) -> tuple[float, float, float]:
    return float(value[0]), float(value[2]), -float(value[1])


def strip_triangles(indices: list[int], lengths: list[int]) -> list[tuple[int, int, int]]:
    result: list[tuple[int, int, int]] = []
    offset = 0
    for length in lengths:
        strip = indices[offset:offset + int(length)]
        offset += int(length)
        for index in range(max(0, len(strip) - 2)):
            a, b, c = strip[index:index + 3]
            if index & 1:
                a, b = b, a
            if a != b and b != c and a != c:
                result.append((int(a), int(b), int(c)))
    if offset != len(indices):
        raise ValueError(f"strip census mismatch: consumed={offset} indices={len(indices)}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--niftest", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--texture-root", type=Path, required=True)
    parser.add_argument("--dependencies-output", type=Path, required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="opennv-geometry-") as temporary:
        dump_path = Path(temporary) / "geometry.json"
        subprocess.run(
            [str(args.niftest), "--fnv-geometry-dump", str(args.input), str(dump_path)],
            check=True,
        )
        document = json.loads(dump_path.read_text(encoding="utf-8"))

    geometries = [row for row in document.get("geometries", []) if row.get("worldVertices")]
    if not geometries:
        raise SystemExit(f"OpenMW found no geometry: {args.input}")
    fallback_textures = embedded_diffuse_candidates(args.input)
    missing_texture_indices = [i for i, row in enumerate(geometries) if not row.get("diffuseTexture")]
    if fallback_textures and len(fallback_textures) == len(missing_texture_indices):
        for index, texture in zip(missing_texture_indices, fallback_textures, strict=True):
            geometries[index]["diffuseTexture"] = texture
    elif fallback_textures:
        for index in missing_texture_indices:
            geometries[index]["diffuseTexture"] = fallback_textures[min(index, len(fallback_textures) - 1)]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    material_path = args.output.with_suffix(".mtl")
    textures: list[str] = []
    render_surfaces: list[bool] = []
    collision_enabled = bool(int(document.get("bsxFlags", 0)) & 2)
    collision_surfaces: list[bool] = []
    with material_path.open("w", encoding="utf-8", newline="\n") as material:
        for index, row in enumerate(geometries):
            diffuse = canonical_texture(str(row.get("diffuseTexture", "")))
            textures.append(diffuse)
            render_surfaces.append(bool(diffuse) and not bool(row.get("hidden", False)))
            is_marker = bool(int(document.get("bsxFlags", 0)) & 32) and str(row.get("name", "")).lower().startswith("editormarker")
            collision_surfaces.append(collision_enabled and not is_marker)
            material.write(f"newmtl nif_surface_{index}\nKd 0.18 0.14 0.10\n")
            if diffuse:
                texture = args.texture_root / Path(diffuse.replace("\\", "/"))
                relative = os.path.relpath(texture, args.output.parent).replace("\\", "/")
                material.write(f"map_Kd {relative}\n")
            material.write("\n")

    vertex_offset = 0
    uv_offset = 0
    with args.output.open("w", encoding="utf-8", newline="\n") as obj:
        obj.write(f"# OpenMW native geometry fallback from {args.input.as_posix()}\n")
        obj.write(f"mtllib {material_path.name}\n")
        for index, row in enumerate(geometries):
            vertices = row.get("worldVertices", [])
            uvs = row.get("uv0", [])
            triangles = [tuple(int(v) for v in triangle) for triangle in row.get("triangleIndices", [])]
            triangles.extend(strip_triangles(row.get("stripIndices", []), row.get("stripLengths", [])))
            obj.write(f"o opennv_geometry_{index}\nusemtl nif_surface_{index}\n")
            for vertex in vertices:
                x, y, z = godot_vertex(vertex)
                obj.write(f"v {x:.9g} {y:.9g} {z:.9g}\n")
            for uv in uvs:
                obj.write(f"vt {float(uv[0]):.9g} {1.0 - float(uv[1]):.9g}\n")
            for triangle in triangles:
                corners = []
                for local in triangle:
                    vertex_index = vertex_offset + local + 1
                    texture_index = uv_offset + local + 1 if len(uvs) == len(vertices) else 0
                    corners.append(f"{vertex_index}/{texture_index}" if texture_index else str(vertex_index))
                obj.write("f " + " ".join(corners) + "\n")
            vertex_offset += len(vertices)
            uv_offset += len(uvs)

    metadata = {
        "textures": sorted(set(value for value in textures if value)),
        "alpha_surfaces": [bool(row.get("alphaBlend", False)) for row in geometries],
        "two_sided_surfaces": [False] * len(geometries),
        "render_surfaces": render_surfaces,
        "collision_surfaces": collision_surfaces,
        "collision_mode": "openmw-bsx-render-geometry-v1",
        "bsx_flags": int(document.get("bsxFlags", 0)),
        "fallback_source": "openmw-fnv-geometry-dump/v2",
        "source_nif_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
        "niftest_sha256": hashlib.sha256(args.niftest.read_bytes()).hexdigest(),
    }
    args.dependencies_output.parent.mkdir(parents=True, exist_ok=True)
    args.dependencies_output.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(
        f"OPENNV_OPENMW_GEOMETRY_OBJ geometries={len(geometries)} vertices={vertex_offset} "
        f"render={sum(render_surfaces)} collision={sum(collision_surfaces)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
