#!/usr/bin/env python3
"""Convert the render geometry in a Gamebryo NIF to a Godot-importable OBJ.

This intentionally handles the static NiTriShape/NiTriStrips subset first. The
source NIF remains the authority; OBJ is only a generated engine cache.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from pathlib import Path

if not hasattr(time, "clock"):
    time.clock = time.perf_counter  # PyFFI compatibility with Python 3.8+

from pyffi.formats.nif import NifFormat  # type: ignore  # noqa: E402


def text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def canonical_texture_path(value: object) -> str:
    path = text(value).replace("/", "\\").lstrip("\\").lower()
    # A few Bethesda shader records store archive-relative paths with a loose
    # install-root prefix. BSA entries themselves always begin at textures\.
    if path.startswith("data\\"):
        path = path[len("data\\"):]
    return path


def diffuse_texture_for_shape(shape: object) -> str:
    """Resolve both Bethesda shader and legacy/effect texture properties."""
    properties = getattr(shape, "properties", [])
    for prop in properties:
        texture_set = getattr(prop, "texture_set", None)
        if texture_set and texture_set.textures:
            candidate = canonical_texture_path(texture_set.textures[0])
            if candidate.endswith(".dds"):
                return candidate
    for prop in properties:
        for attribute in ("file_name", "source_texture"):
            value = getattr(prop, attribute, None)
            if value:
                candidate = canonical_texture_path(value)
                if candidate.endswith(".dds"):
                    return candidate
        base_texture = getattr(prop, "base_texture", None)
        source = getattr(base_texture, "source", None) if base_texture is not None else None
        value = getattr(source, "file_name", None) if source is not None else None
        if value:
            candidate = canonical_texture_path(value)
            if candidate.endswith(".dds"):
                return candidate
    return ""


def transformed(vertex: object, matrix: object, direction: bool = False) -> tuple[float, float, float]:
    # NIF Matrix44 uses row vectors and stores translation in row four.
    x, y, z = float(vertex.x), float(vertex.y), float(vertex.z)
    tx = x * matrix.m_11 + y * matrix.m_21 + z * matrix.m_31
    ty = x * matrix.m_12 + y * matrix.m_22 + z * matrix.m_32
    tz = x * matrix.m_13 + y * matrix.m_23 + z * matrix.m_33
    if not direction:
        tx += matrix.m_41
        ty += matrix.m_42
        tz += matrix.m_43
    # Bethesda is Z-up; Godot is Y-up and looks down -Z. Keep source units so
    # the placement layer can apply the project-wide 1/70 scale exactly once.
    result = (tx, tz, -ty)
    if direction:
        length = math.sqrt(sum(component * component for component in result)) or 1.0
        result = tuple(component / length for component in result)
    return result


def openmw_collision_surfaces(root: object, geometry: list[object]) -> tuple[int, list[bool]]:
    """Mirror OpenMW's FO3/FNV visual-collision selection.

    OpenMW's BulletNifLoader intentionally uses NiGeometry for Gamebryo files,
    but only when the root BSXFlags has the collision bit (2).  Treating every
    converted render surface as collision created invisible clutter barriers
    and made collision cooking scale with the entire visible world.
    """
    flags = 0
    for extra in getattr(root, "extra_data_list", []):
        if isinstance(extra, NifFormat.BSXFlags):
            flags = int(getattr(extra, "integer_data", 0))
            break
    enabled = bool(flags & 2)
    has_editor_markers = bool(flags & 32)
    surfaces = []
    for shape in geometry:
        name = text(getattr(shape, "name", ""))
        is_marker = has_editor_markers and name.lower().startswith("editormarker")
        surfaces.append(enabled and not is_marker)
    return flags, surfaces


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--texture-root", type=Path)
    parser.add_argument("--dependencies-output", type=Path)
    args = parser.parse_args()

    data = NifFormat.Data()
    with args.input.open("rb") as stream:
        data.read(stream)
    if not data.roots:
        raise SystemExit(f"NIF has no roots: {args.input}")

    root = data.roots[0]
    geometry = [
        block for block in data.get_global_iterator()
        if isinstance(block, (NifFormat.NiTriShape, NifFormat.NiTriStrips)) and block.data
    ]
    if not geometry:
        raise SystemExit(f"NIF has no supported render geometry: {args.input}")
    bsx_flags, collision_surfaces = openmw_collision_surfaces(root, geometry)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    diffuse_textures: list[str] = []
    alpha_surfaces: list[bool] = []
    two_sided_surfaces: list[bool] = []
    render_surfaces: list[bool] = []
    for shape in geometry:
        diffuse = diffuse_texture_for_shape(shape)
        diffuse_textures.append(diffuse)
        alpha_surfaces.append(any(isinstance(prop, NifFormat.NiAlphaProperty) for prop in shape.properties))
        two_sided_surfaces.append(any(isinstance(prop, NifFormat.NiStencilProperty) for prop in shape.properties))
        # Retain untextured geometry in the imported resource for collision,
        # but mark it non-rendering. OpenMW's Fallout collision loader uses the
        # complete NiGeometry tree when BSX collision is enabled; throwing these
        # shapes away is what sealed doorways and removed authored floors.
        render_surfaces.append(diffuse.endswith(".dds"))
    if not any(render_surfaces) and not any(collision_surfaces):
        raise SystemExit(f"NIF has neither render nor collision geometry: {args.input}")

    material_path = args.output.with_suffix(".mtl")
    if args.texture_root:
        with material_path.open("w", encoding="utf-8", newline="\n") as material:
            for index, diffuse in enumerate(diffuse_textures):
                # Missing retail/dynamic textures must never become Godot's
                # glaring white default. The authored texture is still listed
                # in metadata; this dark fallback is only visible when it
                # cannot be resolved from the installed load order.
                material.write(f"newmtl nif_surface_{index}\nKd 0.18 0.14 0.10\n")
                if diffuse:
                    texture = args.texture_root / Path(diffuse.replace("\\", "/"))
                    relative = os.path.relpath(texture, args.output.parent).replace("\\", "/")
                    material.write(f"map_Kd {relative}\n")
                material.write("\n")
    if args.dependencies_output:
        args.dependencies_output.parent.mkdir(parents=True, exist_ok=True)
        args.dependencies_output.write_text(
            json.dumps({
                "textures": sorted(set(value for value in diffuse_textures if value)),
                "alpha_surfaces": alpha_surfaces,
                "two_sided_surfaces": two_sided_surfaces,
                "render_surfaces": render_surfaces,
                "collision_surfaces": collision_surfaces,
                "collision_mode": "openmw-bsx-render-geometry-v1",
                "bsx_flags": bsx_flags,
            }, indent=2),
            encoding="utf-8",
        )
    vertex_offset = 0
    uv_offset = 0
    normal_offset = 0
    with args.output.open("w", encoding="utf-8", newline="\n") as obj:
        obj.write(f"# Generated from {args.input.as_posix()}\n")
        if args.texture_root:
            obj.write(f"mtllib {material_path.name}\n")
        for index, shape in enumerate(geometry):
            mesh = shape.data
            matrix = shape.get_transform(root)
            name = text(shape.name).replace(" ", "_") or f"shape_{index}"
            obj.write(f"o {name}\n")
            if args.texture_root:
                obj.write(f"usemtl nif_surface_{index}\n")
            for vertex in mesh.vertices:
                x, y, z = transformed(vertex, matrix)
                obj.write(f"v {x:.7g} {y:.7g} {z:.7g}\n")

            uvs = list(mesh.uv_sets[0]) if mesh.uv_sets else []
            for uv in uvs:
                obj.write(f"vt {float(uv.u):.7g} {1.0 - float(uv.v):.7g}\n")

            normals = list(mesh.normals) if getattr(mesh, "has_normals", False) else []
            for normal in normals:
                x, y, z = transformed(normal, matrix, direction=True)
                obj.write(f"vn {x:.7g} {y:.7g} {z:.7g}\n")

            for triangle in mesh.get_triangles():
                corners: list[str] = []
                for local in triangle:
                    vi = vertex_offset + int(local) + 1
                    ti = uv_offset + int(local) + 1 if uvs else ""
                    ni = normal_offset + int(local) + 1 if normals else ""
                    corners.append(f"{vi}/{ti}/{ni}" if (uvs or normals) else str(vi))
                # (x, y, z) -> (x, z, -y) is a proper rotation (determinant
                # +1), so authored winding must be preserved.
                obj.write("f " + " ".join(corners) + "\n")

            vertex_offset += len(mesh.vertices)
            uv_offset += len(uvs)
            normal_offset += len(normals)

    print(f"OPENNV_NIF_OBJ input={args.input} output={args.output} shapes={len(geometry)} vertices={vertex_offset}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
