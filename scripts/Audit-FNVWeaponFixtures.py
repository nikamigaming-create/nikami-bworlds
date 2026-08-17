#!/usr/bin/env python3
"""Report immutable model-space weapon landmarks from extracted Fallout NIFs."""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

# PyFFI still imports time.clock on Python 3.11.
if not hasattr(time, "clock"):
    time.clock = time.perf_counter  # type: ignore[attr-defined]

from pyffi.formats.nif import NifFormat  # noqa: E402


def name_of(block) -> str:
    value = getattr(block, "name", b"")
    return bytes(value).decode("utf-8", errors="replace") if value else ""


def vec3(value) -> list[float]:
    return [float(value.x), float(value.y), float(value.z)]


def summarize(path: Path) -> dict:
    data = NifFormat.Data()
    with path.open("rb") as stream:
        data.read(stream)
    root = data.roots[0]

    nodes = []
    geometries = []
    for block in data.blocks:
        name = name_of(block)
        if hasattr(block, "get_transform"):
            # NiAVObject exposes get_transform(relative_to), while payload blocks
            # such as NiSkinData expose an unrelated zero-argument helper.  Only
            # scene objects participate in the model-space fixture walk.
            try:
                transform = block.get_transform(root)
            except TypeError:
                continue
            if name and not hasattr(block, "data"):
                nodes.append(
                    {
                        "name": name,
                        "type": type(block).__name__,
                        "translation": vec3(transform.get_translation()),
                        "animated": getattr(block, "controller", None) is not None,
                    }
                )

            geometry_data = getattr(block, "data", None)
            vertices = getattr(geometry_data, "vertices", None)
            if vertices is None or len(vertices) == 0:
                continue
            transformed = [vertex * transform for vertex in vertices]
            minimum = [min(float(getattr(vertex, axis)) for vertex in transformed) for axis in ("x", "y", "z")]
            maximum = [max(float(getattr(vertex, axis)) for vertex in transformed) for axis in ("x", "y", "z")]
            center = [(minimum[index] + maximum[index]) * 0.5 for index in range(3)]
            geometries.append(
                {
                    "name": name,
                    "type": type(block).__name__,
                    "vertexCount": len(transformed),
                    "minimum": minimum,
                    "maximum": maximum,
                    "center": center,
                    "animated": getattr(block, "controller", None) is not None,
                }
            )

    landmark_terms = ("projectile", "trigger", "grip", "handle", "stock", "blade", "sight")
    landmarks = [node for node in nodes if any(term in node["name"].lower() for term in landmark_terms)]
    landmarks += [
        geometry for geometry in geometries if any(term in geometry["name"].lower() for term in landmark_terms)
    ]
    return {
        "path": str(path.resolve()),
        "root": name_of(root),
        "landmarks": landmarks,
        "nodes": nodes,
        "geometries": geometries,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("nifs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = {
        "schema": "nikami-fnv-weapon-fixture-asset-audit/v1",
        "weapons": [summarize(path) for path in args.nifs],
    }
    rendered = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
