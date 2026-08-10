#!/usr/bin/env python3
"""Decode and audit lossless OpenNV actor skin payloads.

The format is emitted from the live, fully assembled OpenMW actor graph.  It
keeps bind vertices, the complete influence list, inverse-bind matrices and the
current bone palette; unlike the legacy OBJ cache it is not a posed snapshot.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any


MAGICS = {b"ONVSKEL1": 1, b"ONVSKEL2": 2}
MAX_COUNT = 10_000_000


def matrix_multiply(left: list[float], right: list[float]) -> list[float]:
    return [
        sum(left[row * 4 + inner] * right[inner * 4 + column] for inner in range(4))
        for row in range(4)
        for column in range(4)
    ]


class DecodeError(ValueError):
    pass


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def read(self, size: int) -> bytes:
        if size < 0 or self.offset + size > len(self.data):
            raise DecodeError(f"truncated payload at offset {self.offset}, need {size} bytes")
        value = self.data[self.offset : self.offset + size]
        self.offset += size
        return value

    def unpack(self, fmt: str) -> tuple[Any, ...]:
        size = struct.calcsize("<" + fmt)
        return struct.unpack("<" + fmt, self.read(size))

    def u16(self) -> int:
        return self.unpack("H")[0]

    def u32(self) -> int:
        return self.unpack("I")[0]

    def i32(self) -> int:
        return self.unpack("i")[0]

    def f32(self) -> float:
        value = self.unpack("f")[0]
        if not math.isfinite(value):
            raise DecodeError(f"non-finite float at offset {self.offset - 4}")
        return value

    def string(self) -> str:
        size = self.u32()
        if size > MAX_COUNT:
            raise DecodeError(f"string length {size} exceeds safety limit")
        try:
            return self.read(size).decode("utf-8")
        except UnicodeDecodeError as error:
            raise DecodeError(f"invalid UTF-8 string at offset {self.offset - size}") from error

    def matrix(self) -> list[float]:
        return [self.f32() for _ in range(16)]


def decode_bytes(data: bytes, *, retain_geometry: bool = False) -> dict[str, Any]:
    reader = Reader(data)
    magic = reader.read(8)
    if magic not in MAGICS:
        raise DecodeError("invalid OpenNV skeletal actor magic")
    version = reader.u32()
    if version != MAGICS[magic]:
        raise DecodeError(f"unsupported OpenNV skeletal actor version {version}")
    surface_count = reader.u32()
    if surface_count > 100_000:
        raise DecodeError(f"surface count {surface_count} exceeds safety limit")

    canonical_bones: list[dict[str, Any]] = []
    canonical_hierarchy_max_residual = 0.0
    if version >= 2:
        canonical_count = reader.u32()
        if canonical_count > MAX_COUNT:
            raise DecodeError(f"canonical bone count {canonical_count} exceeds safety limit")
        canonical_names: set[str] = set()
        for bone_index in range(canonical_count):
            bone_name = reader.string()
            parent = reader.i32()
            if not bone_name or parent < -1 or parent >= bone_index:
                raise DecodeError(f"canonical bone {bone_index} has invalid name or parent {parent}")
            key = bone_name.casefold()
            if key in canonical_names:
                raise DecodeError(f"duplicate canonical bone name {bone_name}")
            canonical_names.add(key)
            canonical_bones.append({
                "name": bone_name,
                "parent": parent,
                "local": reader.matrix(),
                "skeleton": reader.matrix(),
            })
        for bone in canonical_bones:
            parent = int(bone["parent"])
            reconstructed = bone["local"] if parent < 0 else matrix_multiply(
                bone["local"], canonical_bones[parent]["skeleton"]
            )
            residual = max(abs(a - b) for a, b in zip(reconstructed, bone["skeleton"]))
            canonical_hierarchy_max_residual = max(canonical_hierarchy_max_residual, residual)
            if residual > 1e-3:
                raise DecodeError(f"canonical hierarchy residual {residual} exceeds tolerance")

    surfaces: list[dict[str, Any]] = []
    totals = {"vertices": 0, "triangles": 0, "bones": 0, "influences": 0}
    hierarchy_max_residual = 0.0
    hierarchy_failed_edges = 0
    for surface_index in range(surface_count):
        surface_name = reader.string()
        root_bone = reader.string()
        texture = reader.string()
        vertex_count, index_count, bone_count = reader.unpack("III")
        if max(vertex_count, index_count, bone_count) > MAX_COUNT:
            raise DecodeError(f"surface {surface_index} count exceeds safety limit")
        if index_count % 3:
            raise DecodeError(f"surface {surface_index} index count is not triangular")
        transform = reader.matrix()
        skin_to_skeleton = reader.matrix()
        geometry = [reader.f32() for _ in range(vertex_count * 8)]
        indices = list(reader.unpack(f"{index_count}I")) if index_count else []
        if indices and max(indices) >= vertex_count:
            raise DecodeError(f"surface {surface_index} has an out-of-range vertex index")

        bones: list[dict[str, Any]] = []
        for bone_index in range(bone_count):
            bone_name = reader.string()
            parent = reader.i32()
            if parent >= bone_count or parent == bone_index or parent < -1:
                raise DecodeError(f"surface {surface_index} bone {bone_index} has invalid parent {parent}")
            bones.append(
                {
                    "name": bone_name,
                    "parent": parent,
                    "inverse_bind": reader.matrix(),
                    "local": reader.matrix(),
                    "skeleton": reader.matrix(),
                }
            )
        surface_hierarchy_residual = 0.0
        surface_failed_edges = 0
        for bone_index, bone in enumerate(bones):
            visited: set[int] = set()
            cursor = bone_index
            while cursor >= 0:
                if cursor in visited:
                    raise DecodeError(f"surface {surface_index} bone hierarchy contains a cycle")
                visited.add(cursor)
                cursor = int(bones[cursor]["parent"])
            parent = int(bone["parent"])
            reconstructed = bone["local"] if parent < 0 else matrix_multiply(bone["local"], bones[parent]["skeleton"])
            residual = max(abs(a - b) for a, b in zip(reconstructed, bone["skeleton"]))
            surface_hierarchy_residual = max(surface_hierarchy_residual, residual)
            if residual > 1e-3:
                surface_failed_edges += 1
        hierarchy_max_residual = max(hierarchy_max_residual, surface_hierarchy_residual)
        hierarchy_failed_edges += surface_failed_edges

        vertex_influences: list[list[list[float | int]]] = []
        influence_total = 0
        zero_weight_vertices = 0
        for vertex in range(vertex_count):
            count = reader.u16()
            if count > bone_count:
                raise DecodeError(
                    f"surface {surface_index} vertex {vertex} has {count} influences for {bone_count} bones"
                )
            values: list[list[float | int]] = []
            weight_sum = 0.0
            for _ in range(count):
                bone = reader.u16()
                weight = reader.f32()
                if bone >= bone_count:
                    raise DecodeError(
                        f"surface {surface_index} vertex {vertex} references missing bone {bone}"
                    )
                if weight < 0.0:
                    raise DecodeError(f"surface {surface_index} vertex {vertex} has negative weight")
                values.append([bone, weight])
                weight_sum += weight
            if weight_sum <= 1e-8:
                zero_weight_vertices += 1
            influence_total += count
            if retain_geometry:
                vertex_influences.append(values)

        surface: dict[str, Any] = {
            "name": surface_name,
            "root_bone": root_bone,
            "texture": texture,
            "vertex_count": vertex_count,
            "index_count": index_count,
            "triangle_count": index_count // 3,
            "bone_count": bone_count,
            "influence_count": influence_total,
            "zero_weight_vertices": zero_weight_vertices,
            "hierarchy_max_residual": surface_hierarchy_residual,
            "hierarchy_failed_edges": surface_failed_edges,
            "bone_names": [bone["name"] for bone in bones],
        }
        if retain_geometry:
            surface.update(
                geometry=geometry,
                indices=indices,
                bones=bones,
                influences=vertex_influences,
                transform=transform,
                skin_to_skeleton=skin_to_skeleton,
            )
        surfaces.append(surface)
        totals["vertices"] += vertex_count
        totals["triangles"] += index_count // 3
        totals["bones"] += bone_count
        totals["influences"] += influence_total

    if reader.offset != len(data):
        raise DecodeError(f"unconsumed trailing bytes: {len(data) - reader.offset}")
    return {
        "schema": "opennv-skeletal-actor-audit/v2",
        "format_version": version,
        "canonical_bone_count": len(canonical_bones),
        "canonical_hierarchy_max_residual": canonical_hierarchy_max_residual,
        "canonical_bones": canonical_bones if retain_geometry else [
            {"name": bone["name"], "parent": bone["parent"]} for bone in canonical_bones
        ],
        "surface_count": surface_count,
        "totals": totals,
        "hierarchy_max_residual": hierarchy_max_residual,
        "hierarchy_failed_edges": hierarchy_failed_edges,
        "surfaces": surfaces,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("payload", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--retain-geometry", action="store_true")
    args = parser.parse_args()
    data = args.payload.read_bytes()
    result = decode_bytes(data, retain_geometry=args.retain_geometry)
    result["source"] = {
        "path": str(args.payload.resolve()),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
