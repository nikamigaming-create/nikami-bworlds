#!/usr/bin/env python3
"""Derive a Goodsprings road route from placed FalloutNV.esm road meshes."""

from __future__ import annotations

import argparse
import heapq
import importlib.util
import json
import math
from pathlib import Path


ROAD_TOKENS = ("road", "street", "sidewalk", "pavement", "asphalt")


def load_catalog(repo_root: Path, esm: Path):
    source = repo_root / "scripts" / "export_esm4_catalog.py"
    spec = importlib.util.spec_from_file_location("nikami_export_esm4_catalog", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    catalog = module.ESM4Catalog(esm, mod_index=0, terms=[])
    catalog.parse()
    return catalog


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--esm", type=Path, required=True)
    parser.add_argument("--world", default="0xda726")
    parser.add_argument("--start", nargs=2, type=float, required=True)
    parser.add_argument("--end", nargs=2, type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-edge", type=float, default=5500.0)
    parser.add_argument("--atlas", type=Path)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    catalog = load_catalog(repo_root, args.esm)
    world = int(args.world, 16)
    nodes: list[dict] = []
    for placement in catalog.placements:
        position = placement.get("pos")
        parent = placement.get("parentCell")
        base_id = placement.get("base")
        if not position or not parent or not base_id:
            continue
        cell = catalog.cells.get(int(parent, 16))
        if not cell or not cell.get("isExterior") or int(cell.get("parentWorld", "0"), 16) != world:
            continue
        base = catalog.records.get(int(base_id, 16))
        if not base:
            continue
        models = base.get("models", []) or ([base.get("model")] if base.get("model") else [])
        model = str(models[0]).replace("/", "\\").lower() if models else ""
        basename = model.rsplit("\\", 1)[-1]
        if not any(token in basename for token in ROAD_TOKENS):
            continue
        x, y, z = (float(value) for value in position)
        if not (-110000 <= x <= 30000 and -30000 <= y <= 140000):
            continue
        nodes.append({"position": [x, y, z], "form_id": placement["id"], "model": model})

    if not nodes:
        raise RuntimeError("No authored road placements found")
    adjacency: list[list[tuple[float, int]]] = [[] for _ in nodes]
    for left in range(len(nodes)):
        lx, ly = nodes[left]["position"][:2]
        for right in range(left + 1, len(nodes)):
            rx, ry = nodes[right]["position"][:2]
            horizontal = math.hypot(rx - lx, ry - ly)
            if horizontal <= args.max_edge:
                vertical = abs(float(nodes[right]["position"][2]) - float(nodes[left]["position"][2]))
                # Pure Euclidean shortest-path chooses sparse shortcuts between
                # stacked roads and distant mesh origins. Prefer the dense
                # authored chain and penalize elevation discontinuities while
                # retaining long edges where the source uses long road pieces.
                edge_cost = horizontal * (1.0 + 3.0 * horizontal / args.max_edge) + vertical * 2.0
                adjacency[left].append((edge_cost, right))
                adjacency[right].append((edge_cost, left))

    start = min(range(len(nodes)), key=lambda index: math.dist(args.start, nodes[index]["position"][:2]))
    end = min(range(len(nodes)), key=lambda index: math.dist(args.end, nodes[index]["position"][:2]))
    distances = [math.inf] * len(nodes)
    previous = [-1] * len(nodes)
    distances[start] = 0.0
    queue = [(0.0, start)]
    while queue:
        distance, node = heapq.heappop(queue)
        if distance != distances[node]:
            continue
        if node == end:
            break
        for edge, target in adjacency[node]:
            candidate = distance + edge
            if candidate < distances[target]:
                distances[target] = candidate
                previous[target] = node
                heapq.heappush(queue, (candidate, target))
    if not math.isfinite(distances[end]):
        raise RuntimeError(
            f"Authored road graph is disconnected: nodes={len(nodes)} max_edge={args.max_edge} "
            f"start_nearest={math.dist(args.start, nodes[start]['position'][:2]):.1f} "
            f"end_nearest={math.dist(args.end, nodes[end]['position'][:2]):.1f}"
        )

    indices: list[int] = []
    node = end
    while node >= 0:
        indices.append(node)
        node = previous[node]
    indices.reverse()
    route = [dict(nodes[index]) for index in indices]
    route_distance = sum(
        math.dist(route[index - 1]["position"][:2], route[index]["position"][:2])
        for index in range(1, len(route))
    )
    coordinate_space = "world-local"
    if args.atlas:
        atlas = json.loads(args.atlas.read_text(encoding="utf-8"))
        transform = next(
            (item for item in atlas.get("worldspaces", []) if str(item.get("form_id", "")).lower() == args.world.lower()),
            None,
        )
        if transform is None:
            raise RuntimeError(f"World is missing from seamless atlas: {args.world}")
        angle = float(transform.get("rotation_radians", 0.0))
        translation = [float(value) for value in transform.get("translation_units", [0.0, 0.0, 0.0])]
        cosine, sine = math.cos(angle), math.sin(angle)
        for node in route:
            x, y, z = node["position"]
            node["position"] = [
                cosine * x - sine * y + translation[0],
                sine * x + cosine * y + translation[1],
                z + translation[2],
            ]
        coordinate_space = "seamless-atlas"
    document = {
        "schema": "opennv-godot-authored-road-route/v1",
        "status": "pass",
        "world_form_id": args.world.lower(),
        "start": args.start,
        "end": args.end,
        "node_count": len(nodes),
        "max_edge_units": args.max_edge,
        "route_distance_units": route_distance,
        "route_cost": distances[end],
        "coordinate_space": coordinate_space,
        "waypoint_count": len(route),
        "waypoints": route,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(
        f"OPENNV_AUTHORED_ROAD_ROUTE nodes={len(nodes)} waypoints={len(route)} "
        f"distance_units={route_distance:.1f} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
