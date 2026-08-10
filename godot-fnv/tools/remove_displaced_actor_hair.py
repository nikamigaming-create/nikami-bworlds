#!/usr/bin/env python3
"""Remove the duplicated, misbased FNV scalp-hair copy from actor OBJ caches."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import numpy as np


MAP_KD = re.compile(r"^map_Kd\s+(.+?)\s*$", re.I)


def material_textures(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    current = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("newmtl "):
            current = line.split(None, 1)[1]
        else:
            match = MAP_KD.match(line)
            if match and current:
                result[current] = match.group(1).replace("\\", "/").lower()
    return result


def eligible_hair(texture: str) -> bool:
    leaf = texture.rsplit("/", 1)[-1]
    return "/characters/hair/" in texture and leaf.startswith("hair") and not any(
        token in leaf for token in ("eyebrow", "beard", "glasses")
    )


def clean_obj(path: Path) -> list[str]:
    marker = "# OPENNV_DISPLACED_HAIR_REMOVED_V1"
    lines = path.read_text(encoding="utf-8").splitlines()
    if marker in lines[:8]:
        return []
    textures = material_textures(path.with_suffix(".mtl"))
    vertices: list[tuple[float, float, float]] = []
    groups: dict[str, set[int]] = {}
    current = ""
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "v":
            vertices.append(tuple(map(float, parts[1:4])))
        elif parts[0] == "g":
            current = parts[1]
            groups.setdefault(current, set())
        elif parts[0] == "f":
            groups.setdefault(current, set()).update(int(value.split("/")[0]) - 1 for value in parts[1:])

    by_texture: dict[str, list[tuple[str, np.ndarray]]] = {}
    for group, indices in groups.items():
        texture = textures.get(group, "")
        if not indices or not eligible_hair(texture):
            continue
        center = np.asarray([vertices[index] for index in indices], dtype=np.float64).mean(axis=0)
        by_texture.setdefault(texture, []).append((group, center))

    remove: set[str] = set()
    for candidates in by_texture.values():
        good = [row for row in candidates if row[1][1] >= 116.0 and abs(row[1][2]) <= 5.0]
        displaced = [row for row in candidates if 103.0 <= row[1][1] <= 115.5 and row[1][2] >= 5.0]
        if good:
            remove.update(group for group, _ in displaced)
    if not remove:
        return []

    output = [lines[0], marker, *lines[1:]]
    filtered: list[str] = []
    current = ""
    for line in output:
        if line.startswith("g "):
            current = line.split(None, 1)[1]
        if current in remove and line.startswith("f "):
            continue
        filtered.append(line)
    path.write_text("\n".join(filtered) + "\n", encoding="utf-8", newline="\n")
    return sorted(remove)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    changed: list[dict] = []
    seen: set[Path] = set()
    for actor in manifest.get("actors", []):
        resource = str(actor.get("mesh", ""))
        if not resource.startswith("res://"):
            continue
        path = (args.project_root / resource[6:]).resolve()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        removed = clean_obj(path)
        if removed:
            changed.append({"mesh": str(path), "surfaces": removed})
    print("OPENNV_HAIR_CLEANUP " + json.dumps({"status": "pass", "meshes": len(changed), "changes": changed}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
