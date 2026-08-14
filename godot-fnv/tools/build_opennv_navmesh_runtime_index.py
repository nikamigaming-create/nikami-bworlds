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


def centroid(navmesh: dict, triangle_index: int) -> tuple[float, float, float]:
    triangle = navmesh["triangles"][triangle_index]
    points = [navmesh["vertices"][index] for index in triangle]
    return tuple(sum(float(point[axis]) for point in points) / 3.0 for axis in range(3))


def nearest_triangle_pair(source: dict, target: dict) -> tuple[int, int, float]:
    source_centers = [centroid(source, index) for index in range(len(source["triangles"]))]
    target_centers = [centroid(target, index) for index in range(len(target["triangles"]))]
    best = (-1, -1, float("inf"))
    for source_index, source_center in enumerate(source_centers):
        for target_index, target_center in enumerate(target_centers):
            distance_squared = sum(
                (source_center[axis] - target_center[axis]) ** 2 for axis in range(3))
            if distance_squared < best[2]:
                best = (source_index, target_index, distance_squared)
    return best


def nearest_source_triangle(source: dict, target_center: tuple[float, float, float]) -> tuple[int, float]:
    best = (-1, float("inf"))
    for source_index in range(len(source["triangles"])):
        source_center = centroid(source, source_index)
        distance_squared = sum(
            (source_center[axis] - target_center[axis]) ** 2 for axis in range(3))
        if distance_squared < best[1]:
            best = (source_index, distance_squared)
    return best


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

    declared_navmesh_artifacts = {
        str(artifact["path"]): artifact
        for artifact in manifest.get("artifacts", [])
        if str(artifact.get("path", "")).startswith("navmeshes/")
    }
    input_paths = sorted((semantic_dir / "navmeshes").glob("*.json"))
    observed_relative_paths = {path.relative_to(semantic_dir).as_posix() for path in input_paths}
    if observed_relative_paths != set(declared_navmesh_artifacts):
        raise RuntimeError("semantic NAVM shard set differs from the semantic manifest")
    navmesh_input_rows = []
    for path in input_paths:
        relative_path = path.relative_to(semantic_dir).as_posix()
        content = path.read_bytes()
        declared = declared_navmesh_artifacts[relative_path]
        digest = hashlib.sha256(content).hexdigest()
        if digest != declared.get("sha256") or len(content) != int(declared.get("bytes", -1)):
            raise RuntimeError(f"semantic NAVM shard provenance mismatch: {relative_path}")
        navmesh_input_rows.append((relative_path, digest, len(content)))
    navmesh_inputs_sha256 = hashlib.sha256(encoded(navmesh_input_rows)).hexdigest()

    by_cell: dict[str, list[dict]] = defaultdict(list)
    navmesh_count = 0
    vertex_count = 0
    triangle_count = 0
    for path in input_paths:
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

    by_id = {
        navmesh["id"]: navmesh
        for navmeshes in by_cell.values()
        for navmesh in navmeshes
    }
    cell_by_navmesh = {
        navmesh["id"]: cell
        for cell, navmeshes in by_cell.items()
        for navmesh in navmeshes
    }
    repaired_external_connections = 0
    cell_edge_by_pair: dict[tuple[str, str], tuple[float, dict]] = {}
    for navmeshes in by_cell.values():
        for source in navmeshes:
            repaired_connections = []
            for connection_value in source["external_connections"]:
                connection = dict(connection_value)
                target = by_id.get(str(connection.get("navmesh", "")).lower())
                target_triangle = int(connection.get("triangle", -1))
                if target is not None and not 0 <= target_triangle < len(target["triangles"]):
                    source_triangle, corrected_target_triangle, distance_squared = nearest_triangle_pair(source, target)
                    if source_triangle < 0 or distance_squared > (12.0 * 70.0) ** 2:
                        raise RuntimeError(
                            f"NAVM {source['id']} malformed external edge cannot be repaired: {connection}")
                    connection["original_triangle"] = target_triangle
                    connection["triangle"] = corrected_target_triangle
                    connection["source_triangle"] = source_triangle
                    connection["repaired"] = True
                    repaired_external_connections += 1
                if target is not None:
                    target_triangle = int(connection.get("triangle", -1))
                    if 0 <= target_triangle < len(target["triangles"]):
                        target_center = centroid(target, target_triangle)
                        source_triangle = int(connection.get("source_triangle", -1))
                        if not 0 <= source_triangle < len(source["triangles"]):
                            source_triangle, distance_squared = nearest_source_triangle(source, target_center)
                            connection["source_triangle"] = source_triangle
                        else:
                            source_center = centroid(source, source_triangle)
                            distance_squared = sum(
                                (source_center[axis] - target_center[axis]) ** 2 for axis in range(3))
                        source_cell = cell_by_navmesh[source["id"]]
                        target_cell = cell_by_navmesh[target["id"]]
                        if source_cell != target_cell and distance_squared <= (12.0 * 70.0) ** 2:
                            source_center = centroid(source, source_triangle)
                            edge = {
                                "cell": target_cell,
                                "sourceNavmesh": source["id"],
                                "targetNavmesh": target["id"],
                                "sourcePosition": list(source_center),
                                "targetPosition": list(target_center),
                                "repaired": bool(connection.get("repaired", False)),
                            }
                            pair = (source_cell, target_cell)
                            if pair not in cell_edge_by_pair or distance_squared < cell_edge_by_pair[pair][0]:
                                cell_edge_by_pair[pair] = (distance_squared, edge)
                repaired_connections.append(connection)
            source["external_connections"] = repaired_connections

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
        "semantic_navmesh_inputs_sha256": navmesh_inputs_sha256,
        "load_order_sha256": manifest["load_order_sha256"],
        "counts": {
            "cells": len(cells),
            "navmeshes": navmesh_count,
            "vertices": vertex_count,
            "triangles": triangle_count,
            "repaired_external_connections": repaired_external_connections,
            "external_cell_edges": len(cell_edge_by_pair),
            "shard_bytes": artifact_bytes,
        },
        "cells": cells,
        "cell_adjacency": {
            cell: [edge for (_distance, edge) in sorted(
                (value for pair, value in cell_edge_by_pair.items() if pair[0] == cell),
                key=lambda item: int(item[1]["cell"], 16))]
            for cell in sorted({pair[0] for pair in cell_edge_by_pair}, key=lambda value: int(value, 16))
        },
    }
    output_path.write_bytes(json.dumps(index, indent=2, sort_keys=True).encode("utf-8") + b"\n")
    print("OPENNV_NAVMESH_RUNTIME " + json.dumps(index["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
