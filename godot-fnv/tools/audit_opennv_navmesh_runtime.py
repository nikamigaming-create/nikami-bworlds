#!/usr/bin/env python3
"""Validate the complete cell-owned Godot NAVM runtime artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
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
    if index.get("load_order_sha256") != semantic.get("load_order_sha256"):
        failures.append("load-order-provenance")
    semantic_dir = args.semantic_manifest.parent
    declared_navmesh_artifacts = sorted(
        (str(artifact["path"]), str(artifact["sha256"]), int(artifact["bytes"]))
        for artifact in semantic.get("artifacts", [])
        if str(artifact.get("path", "")).startswith("navmeshes/")
    )
    observed_navmesh_inputs = []
    for relative_path, declared_hash, declared_bytes in declared_navmesh_artifacts:
        path = semantic_dir / relative_path
        if not path.is_file():
            failures.append(f"missing-semantic-navmesh-shard:{relative_path}")
            continue
        content = path.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        if digest != declared_hash or len(content) != declared_bytes:
            failures.append(f"semantic-navmesh-provenance:{relative_path}")
        observed_navmesh_inputs.append((relative_path, digest, len(content)))
    navmesh_inputs_sha256 = hashlib.sha256(json.dumps(
        observed_navmesh_inputs, ensure_ascii=False, sort_keys=True,
        separators=(",", ":")).encode("utf-8")).hexdigest()
    if index.get("semantic_navmesh_inputs_sha256") != navmesh_inputs_sha256:
        failures.append("semantic-navmesh-input-provenance")
    if int(index.get("counts", {}).get("navmeshes", -1)) != int(semantic["counts"]["navmeshes"]):
        failures.append("semantic-navmesh-census")

    cells = navmeshes = vertices = triangles = invalid_indices = shard_bytes = 0
    navmesh_triangle_counts: dict[str, int] = {}
    navmesh_cells: dict[str, str] = {}
    external_connections: list[tuple[str, str, int, bool, int, int]] = []
    duplicate_navmesh_ids = 0
    for cell, row in index.get("cells", {}).items():
        path = Path(row.get("shard", ""))
        if not path.is_file():
            failures.append(f"missing-shard:{cell}")
            continue
        content = path.read_bytes()
        shard_bytes += len(content)
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
            navmesh_id = str(navmesh.get("id", "")).lower()
            local_vertices = navmesh.get("vertices", [])
            local_triangles = navmesh.get("triangles", [])
            if not navmesh_id or navmesh_id in navmesh_triangle_counts:
                duplicate_navmesh_ids += 1
            else:
                navmesh_triangle_counts[navmesh_id] = len(local_triangles)
                navmesh_cells[navmesh_id] = cell
            vertices += len(local_vertices)
            triangles += len(local_triangles)
            if (len(navmesh.get("triangle_flags", [])) != len(local_triangles)
                    or len(navmesh.get("triangle_edges", [])) != len(local_triangles)):
                failures.append(f"triangle-metadata:{navmesh.get('id')}")
            for triangle in local_triangles:
                if len(triangle) != 3 or any(not isinstance(value, int) or value < 0 or value >= len(local_vertices) for value in triangle):
                    invalid_indices += 1
            for connection in navmesh.get("external_connections", []):
                external_connections.append((
                    navmesh_id,
                    str(connection.get("navmesh", "")).lower(),
                    int(connection.get("triangle", -1)),
                    bool(connection.get("repaired", False)),
                    int(connection.get("source_triangle", -1)),
                    int(connection.get("original_triangle", -1)),
                ))
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
    if shard_bytes != int(index.get("counts", {}).get("shard_bytes", -1)):
        failures.append("index-census:shard_bytes")
    missing_external_targets = 0
    invalid_external_triangles = 0
    missing_source_triangles = 0
    invalid_source_triangles = 0
    repaired_external_connections = 0
    invalid_repair_metadata = 0
    invalid_external_examples: list[dict] = []
    for _source_id, target_id, target_triangle, repaired, source_triangle, original_triangle in external_connections:
        if source_triangle < 0:
            missing_source_triangles += 1
        elif source_triangle >= navmesh_triangle_counts.get(_source_id, 0):
            invalid_source_triangles += 1
        if target_id not in navmesh_triangle_counts:
            missing_external_targets += 1
        elif target_triangle < 0 or target_triangle >= navmesh_triangle_counts[target_id]:
            invalid_external_triangles += 1
            if len(invalid_external_examples) < 100:
                invalid_external_examples.append({
                    "source": _source_id, "target": target_id,
                    "triangle": target_triangle,
                    "targetTriangleCount": navmesh_triangle_counts[target_id],
                })
        if repaired:
            repaired_external_connections += 1
            if (source_triangle < 0 or source_triangle >= navmesh_triangle_counts.get(_source_id, 0)
                    or original_triangle < navmesh_triangle_counts.get(target_id, 0)):
                invalid_repair_metadata += 1
    if duplicate_navmesh_ids:
        failures.append("duplicate-navmesh-ids")
    if missing_external_targets:
        failures.append("missing-external-targets")
    if invalid_external_triangles:
        failures.append("external-triangle-indices")
    if missing_source_triangles:
        failures.append("missing-external-source-triangles")
    if invalid_source_triangles:
        failures.append("invalid-external-source-triangles")
    if invalid_repair_metadata:
        failures.append("invalid-external-repair-metadata")
    if repaired_external_connections != int(index.get("counts", {}).get("repaired_external_connections", -1)):
        failures.append("external-repair-census")
    external_cell_edges = 0
    invalid_cell_edges = 0
    for source_cell, edges in index.get("cell_adjacency", {}).items():
        seen_targets: set[str] = set()
        for edge in edges:
            external_cell_edges += 1
            target_cell = str(edge.get("cell", "")).lower()
            source_navmesh = str(edge.get("sourceNavmesh", "")).lower()
            target_navmesh = str(edge.get("targetNavmesh", "")).lower()
            positions = [edge.get("sourcePosition", []), edge.get("targetPosition", [])]
            if (source_cell not in index.get("cells", {}) or target_cell not in index.get("cells", {})
                    or target_cell in seen_targets
                    or navmesh_cells.get(source_navmesh) != source_cell
                    or navmesh_cells.get(target_navmesh) != target_cell
                    or any(len(position) != 3 or not all(math.isfinite(float(value)) for value in position)
                           for position in positions)):
                invalid_cell_edges += 1
            seen_targets.add(target_cell)
    if external_cell_edges != int(index.get("counts", {}).get("external_cell_edges", -1)):
        failures.append("external-cell-edge-census")
    if invalid_cell_edges:
        failures.append("invalid-external-cell-edges")
    report = {
        "schema": "opennv-navmesh-runtime-audit/v1",
        "status": "pass" if not failures else "fail",
        "counts": observed | {
            "invalid_triangle_indices": invalid_indices,
            "external_connections": len(external_connections),
            "duplicate_navmesh_ids": duplicate_navmesh_ids,
            "missing_external_targets": missing_external_targets,
            "invalid_external_triangles": invalid_external_triangles,
            "missing_source_triangles": missing_source_triangles,
            "invalid_source_triangles": invalid_source_triangles,
            "repaired_external_connections": repaired_external_connections,
            "invalid_repair_metadata": invalid_repair_metadata,
            "external_cell_edges": external_cell_edges,
            "invalid_external_cell_edges": invalid_cell_edges,
            "failures": len(failures),
        },
        "failures": failures[:100],
        "invalidExternalExamples": invalid_external_examples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_NAVMESH_RUNTIME_AUDIT " + json.dumps(report["counts"], sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
