#!/usr/bin/env python3
"""Prepare lossless OpenNV skeletal actors plus legacy OBJ fallbacks."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
from pathlib import Path

from decode_opennv_skeletal_actor import decode_bytes


MAP_PATTERN = re.compile(r"^map_Kd\s+(.+?)\s*$", re.IGNORECASE)
PREPARED_MARKER = "# OPENNV_GODOT_ACTOR_COORDINATES_V1"


def transform_vector(parts: list[str], inverse_yaw: float) -> str:
    x, y, z = (float(parts[index]) for index in range(1, 4))
    cosine = math.cos(inverse_yaw)
    sine = math.sin(inverse_yaw)
    local_x = cosine * x - sine * y
    local_y = sine * x + cosine * y
    # Bethesda/OpenSceneGraph is Z-up; Godot is Y-up and looks down -Z.
    return f"{parts[0]} {local_x:.9g} {z:.9g} {-local_y:.9g}"


def prepare_obj(path: Path, staging_yaw: float) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    if lines and lines[0] == PREPARED_MARKER:
        return
    inverse_yaw = -staging_yaw
    output = [PREPARED_MARKER]
    for line in lines:
        parts = line.split()
        if len(parts) >= 4 and parts[0] in ("v", "vn"):
            output.append(transform_vector(parts, inverse_yaw))
        else:
            output.append(line)
    path.write_text("\n".join(output) + "\n", encoding="utf-8", newline="\n")


def material_textures(path: Path) -> list[str]:
    result: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = MAP_PATTERN.match(line)
        if match:
            result.append(match.group(1).replace("/", "\\").lstrip("\\").lower())
    return result


def rewrite_material(path: Path, converted_root: Path) -> None:
    output: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = MAP_PATTERN.match(line)
        if not match:
            output.append(line)
            continue
        relative = match.group(1).replace("/", os.sep).replace("\\", os.sep).lstrip(os.sep)
        target = converted_root / relative
        output.append("map_Kd " + os.path.relpath(target, path.parent).replace("\\", "/"))
    path.write_text("\n".join(output) + "\n", encoding="utf-8", newline="\n")


def extract_texture(bsatool: Path, archives: list[Path], relative: str, converted_root: Path) -> None:
    target = converted_root / Path(relative.replace("\\", os.sep))
    if target.is_file():
        return
    for archive in archives:
        subprocess.run(
            [str(bsatool), "extract", "-f", str(archive), relative, str(converted_root)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if target.is_file():
            return
    raise RuntimeError(f"Authored actor texture was not found in official archives: {relative}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--bsatool", type=Path, required=True)
    parser.add_argument("--staging-yaw", type=float, default=5.639382362365723)
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8"))
    actors = report.get("actors", [])
    if report.get("status") != "pass" or not actors:
        raise RuntimeError(f"Actor export report is not a passing nonempty roster: {args.report}")
    project_root = args.project_root.resolve()
    converted_root = project_root / "generated" / "assets" / "converted"
    archives = [
        args.data_root / "Fallout - Textures.bsa",
        args.data_root / "Fallout - Textures2.bsa",
    ]
    for required in [args.bsatool, *archives]:
        if not required.is_file():
            raise FileNotFoundError(required)

    textures: set[str] = set()
    mesh_root: Path | None = None
    skeletal_totals = {"surfaces": 0, "vertices": 0, "triangles": 0, "bones": 0}
    skeletal_formats: set[int] = set()
    for actor in actors:
        obj = Path(actor["obj"]).resolve()
        mtl = Path(actor["mtl"]).resolve()
        skeletal = obj.with_suffix(".onvskel")
        if obj.stat().st_size <= 128 or mtl.stat().st_size <= 32:
            raise RuntimeError(f"Actor export is empty: {obj}")
        if not skeletal.is_file() or skeletal.stat().st_size <= 16:
            raise RuntimeError(f"Lossless skeletal actor export is missing: {skeletal}")
        skeletal_audit = decode_bytes(skeletal.read_bytes())
        if skeletal_audit["surface_count"] <= 0:
            raise RuntimeError(f"Actor has no exported skeletal surfaces: {skeletal}")
        skeletal_formats.add(int(skeletal_audit["format_version"]))
        skeletal_totals["surfaces"] += skeletal_audit["surface_count"]
        for key in ("vertices", "triangles", "bones"):
            skeletal_totals[key] += skeletal_audit["totals"][key]
        mesh_root = obj.parent if mesh_root is None else mesh_root
        if obj.parent != mesh_root or mtl.parent != mesh_root:
            raise RuntimeError("Actor export report spans multiple mesh roots")
        prepare_obj(obj, args.staging_yaw)
        textures.update(material_textures(mtl))

    for texture in sorted(textures):
        extract_texture(args.bsatool, archives, texture, converted_root)
    assert mesh_root is not None
    for actor in actors:
        rewrite_material(Path(actor["mtl"]), converted_root)

    manifest_actors = []
    for actor in actors:
        obj = Path(actor["obj"]).resolve()
        resource_path = "res://" + obj.relative_to(project_root).as_posix()
        skeletal_path = "res://" + obj.with_suffix(".onvskel").relative_to(project_root).as_posix()
        manifest_actors.append(
            {
                "index": int(actor["index"]),
                "id": actor["id"],
                "category": actor["category"],
                "authored_ref": actor["authoredRef"].lower(),
                "base_form": actor["base"].lower(),
                "mesh": resource_path,
                "skeletal": skeletal_path,
            }
        )
    manifest = {
        "schema": "opennv-godot-actor-cache/v2",
        "status": "pass",
        "source_report": str(args.report.resolve()),
        "roster_sha256": report["rosterSha256"],
        "actor_count": len(manifest_actors),
        "texture_count": len(textures),
        "native_screenshot_count": report["nativeScreenshotCount"],
        "coordinate_transform": "inverse-common-staging-yaw; bethesda-z-up-to-godot-y-up",
        "skeletal_format": (
            "ONVSKEL2" if skeletal_formats == {2}
            else "ONVSKEL3" if skeletal_formats == {3}
            else "mixed"
        ),
        "skeletal_totals": skeletal_totals,
        "actors": manifest_actors,
    }
    manifest_path = mesh_root / "actor-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"OPENNV_GODOT_ACTORS_READY actors={len(manifest_actors)} "
        f"skeletalSurfaces={skeletal_totals['surfaces']} textures={len(textures)} manifest={manifest_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
