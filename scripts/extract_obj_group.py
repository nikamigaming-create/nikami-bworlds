#!/usr/bin/env python3
"""Extract matching OBJ groups into a compact, index-remapped OBJ."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--group", required=True, help="Regular expression matched against g/o names")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite: {args.output}")
    pattern = re.compile(args.group)
    faces: list[tuple[str, list[str]]] = []
    used_v: set[int] = set()
    used_vt: set[int] = set()
    used_vn: set[int] = set()
    active = False
    material = ""
    mtllib = ""
    with args.input.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            if line.startswith("mtllib "):
                mtllib = line.strip()
            elif line.startswith(("g ", "o ")):
                active = pattern.search(line[2:].strip()) is not None
            elif line.startswith("usemtl "):
                material = line[7:].strip()
            elif active and line.startswith("f "):
                tokens = line.split()[1:]
                faces.append((material, tokens))
                for token in tokens:
                    parts = token.split("/")
                    used_v.add(int(parts[0]))
                    if len(parts) > 1 and parts[1]:
                        used_vt.add(int(parts[1]))
                    if len(parts) > 2 and parts[2]:
                        used_vn.add(int(parts[2]))
    if not faces:
        raise SystemExit("group expression selected no faces")

    values_v: dict[int, str] = {}
    values_vt: dict[int, str] = {}
    values_vn: dict[int, str] = {}
    counts = {"v": 0, "vt": 0, "vn": 0}
    wanted = {"v": used_v, "vt": used_vt, "vn": used_vn}
    values = {"v": values_v, "vt": values_vt, "vn": values_vn}
    with args.input.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            kind = line.split(" ", 1)[0]
            if kind not in counts:
                continue
            counts[kind] += 1
            if counts[kind] in wanted[kind]:
                values[kind][counts[kind]] = line

    maps = {kind: {old: new for new, old in enumerate(sorted(ids), 1)} for kind, ids in wanted.items()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as target:
        target.write("# Compact group extraction for OpenDAO/OpenMW\n")
        if mtllib:
            target.write(mtllib + "\n")
        for kind in ("v", "vt", "vn"):
            for old in sorted(wanted[kind]):
                target.write(values[kind][old])
        target.write("g OpenDAO_Extracted_Background\n")
        current_material = None
        for face_material, tokens in faces:
            if face_material != current_material:
                target.write(f"usemtl {face_material}\n")
                current_material = face_material
            converted = []
            for token in tokens:
                parts = token.split("/")
                result = [str(maps["v"][int(parts[0])])]
                if len(parts) > 1:
                    result.append(str(maps["vt"][int(parts[1])]) if parts[1] else "")
                if len(parts) > 2:
                    result.append(str(maps["vn"][int(parts[2])]) if parts[2] else "")
                converted.append("/".join(result))
            target.write("f " + " ".join(converted) + "\n")
    print(f"faces={len(faces)} vertices={len(used_v)} output={args.output}")


if __name__ == "__main__":
    main()
