#!/usr/bin/env python3
"""Build cell-owned, externally sharded NAVM runtime data for Godot."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path


def encoded(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--semantic-db", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--output-shards-dir", type=Path, required=True)
    args = parser.parse_args()

    semantic_dir = args.semantic_db.resolve()
    output_path = args.output.resolve()
    shard_dir = args.output_shards_dir.resolve()
    manifest_path = semantic_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = int(manifest["counts"]["navmeshes"])

    by_cell: dict[str, list[dict]] = defaultdict(list)
    navmesh_count = 0
    vertex_count = 0
    triangle_count = 0
    for path in sorted((semantic_dir / "navmeshes").glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        for row in payload.get("navmeshes", []):
            data = row["navmeshData"]
            cell = str(data.get("cell") or row.get("parentCell") or "").lower()
            if not cell:
                raise RuntimeError(f"NAVM {row.get('id')} has no owning cell")
            triangles = data.get("triangles", [])
            compact = {
                "id": str(row["id"]).lower(),
                "vertices": data.get("vertices", []),
                "triangles": [triangle["vertices"] for triangle in triangles],
                "triangle_flags": [int(triangle.get("flags", 0)) for triangle in triangles],
                "triangle_edges": [triangle.get("edges", []) for triangle in triangles],
                "external_connections": data.get("externalConnections", []),
                "door_triangles": data.get("doorTriangles", []),
                "bounds": data.get("bounds", {}),
            }
            by_cell[cell].append(compact)
            navmesh_count += 1
            vertex_count += len(compact["vertices"])
            triangle_count += len(compact["triangles"])
    if navmesh_count != expected:
        raise RuntimeError(f"runtime NAVM census {navmesh_count} differs from semantic database {expected}")

    shard_dir.mkdir(parents=True, exist_ok=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cells = {}
    artifact_bytes = 0
    for cell, navmeshes in sorted(by_cell.items(), key=lambda item: int(item[0], 16)):
        filename = f"cell-{int(cell, 16):08x}.json"
        content = encoded({
            "schema": "opennv-navmesh-cell-shard/v1",
            "cell": cell,
            "navmeshes": navmeshes,
        })
        path = shard_dir / filename
        path.write_bytes(content)
        artifact_bytes += len(content)
        cells[cell] = {
            "shard": path.as_posix(),
            "sha256": hashlib.sha256(content).hexdigest(),
            "navmeshes": len(navmeshes),
            "vertices": sum(len(navmesh["vertices"]) for navmesh in navmeshes),
            "triangles": sum(len(navmesh["triangles"]) for navmesh in navmeshes),
        }

    index = {
        "schema": "opennv-navmesh-runtime-index/v1",
        "semantic_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "load_order_sha256": manifest["load_order_sha256"],
        "counts": {
            "cells": len(cells),
            "navmeshes": navmesh_count,
            "vertices": vertex_count,
            "triangles": triangle_count,
            "shard_bytes": artifact_bytes,
        },
        "cells": cells,
    }
    output_path.write_bytes(json.dumps(index, indent=2, sort_keys=True).encode("utf-8") + b"\n")
    print("OPENNV_NAVMESH_RUNTIME " + json.dumps(index["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
