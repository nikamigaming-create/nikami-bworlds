#!/usr/bin/env python3
"""Validate the complete cell-owned Godot NAVM runtime artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--semantic-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    index = json.loads(args.index.read_text(encoding="utf-8"))
    semantic = json.loads(args.semantic_manifest.read_text(encoding="utf-8"))
    failures = []
    if index.get("schema") != "opennv-navmesh-runtime-index/v1":
        failures.append("schema")
    semantic_hash = hashlib.sha256(args.semantic_manifest.read_bytes()).hexdigest()
    if index.get("semantic_manifest_sha256") != semantic_hash:
        failures.append("semantic-manifest-provenance")
    if int(index.get("counts", {}).get("navmeshes", -1)) != int(semantic["counts"]["navmeshes"]):
        failures.append("semantic-navmesh-census")

    cells = navmeshes = vertices = triangles = invalid_indices = 0
    for cell, row in index.get("cells", {}).items():
        path = Path(row.get("shard", ""))
        if not path.is_file():
            failures.append(f"missing-shard:{cell}")
            continue
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != row.get("sha256"):
            failures.append(f"shard-hash:{cell}")
            continue
        payload = json.loads(content)
        if payload.get("schema") != "opennv-navmesh-cell-shard/v1" or payload.get("cell") != cell:
            failures.append(f"shard-identity:{cell}")
            continue
        cells += 1
        for navmesh in payload.get("navmeshes", []):
            navmeshes += 1
            local_vertices = navmesh.get("vertices", [])
            local_triangles = navmesh.get("triangles", [])
            vertices += len(local_vertices)
            triangles += len(local_triangles)
            if (len(navmesh.get("triangle_flags", [])) != len(local_triangles)
                    or len(navmesh.get("triangle_edges", [])) != len(local_triangles)):
                failures.append(f"triangle-metadata:{navmesh.get('id')}")
            for triangle in local_triangles:
                if len(triangle) != 3 or any(not isinstance(value, int) or value < 0 or value >= len(local_vertices) for value in triangle):
                    invalid_indices += 1
        if (int(row.get("navmeshes", -1)) != len(payload.get("navmeshes", []))
                or int(row.get("vertices", -1)) != sum(len(item.get("vertices", [])) for item in payload.get("navmeshes", []))
                or int(row.get("triangles", -1)) != sum(len(item.get("triangles", [])) for item in payload.get("navmeshes", []))):
            failures.append(f"cell-census:{cell}")

    observed = {"cells": cells, "navmeshes": navmeshes, "vertices": vertices, "triangles": triangles}
    for key, value in observed.items():
        if value != int(index.get("counts", {}).get(key, -1)):
            failures.append(f"index-census:{key}")
    if invalid_indices:
        failures.append("triangle-indices")
    report = {
        "schema": "opennv-navmesh-runtime-audit/v1",
        "status": "pass" if not failures else "fail",
        "counts": observed | {"invalid_triangle_indices": invalid_indices, "failures": len(failures)},
        "failures": failures[:100],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_NAVMESH_RUNTIME_AUDIT " + json.dumps(report["counts"], sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
