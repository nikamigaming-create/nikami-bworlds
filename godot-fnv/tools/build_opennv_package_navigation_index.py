#!/usr/bin/env python3
"""Compile PACK reference targets and the complete XTEL cell/door graph."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict, deque
from pathlib import Path


def canonical(value: object) -> str:
    text = str(value or "").strip().casefold()
    if not text:
        return ""
    return f"0x{int(text, 16 if text.startswith('0x') else 10):08x}"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-index", type=Path, required=True)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--blueprints", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    runtime = json.loads(args.runtime_index.read_text(encoding="utf-8"))
    packages_doc = json.loads(args.packages.read_text(encoding="utf-8"))
    blueprints_doc = json.loads(args.blueprints.read_text(encoding="utf-8"))
    if runtime.get("schema") != "opennv-resolved-runtime-ring/v1" or not runtime.get("counts", {}).get("allCells"):
        raise SystemExit("full resolved runtime index is required")
    if packages_doc.get("schema") != "opennv-semantic-actor-packages/v1":
        raise SystemExit("unexpected PACK schema")
    if blueprints_doc.get("schema") != "opennv-actor-blueprints/v1":
        raise SystemExit("unexpected actor blueprint schema")

    requested_targets: set[str] = set()
    package_targets: dict[str, list[str]] = {}
    package_semantics: dict[str, dict] = {}
    linked_location_packages: set[str] = set()
    explicit_reference_rows = 0
    for package in packages_doc.get("packages", []):
        package_id = canonical(package.get("id"))
        refs: list[str] = []
        location = package.get("packageLocation") or {}
        target = package.get("packageTarget") or {}
        package_type = int((package.get("packageData") or {}).get("type", -1))
        location_type = int(location.get("type", -1))
        package_semantics[package_id] = {
            "packageType": package_type,
            "locationType": location_type,
        }
        # XLKR is consumed only by PACK location type 6. A zero-radius Patrol
        # at explicit/current/editor location remains a valid non-linked
        # package; broadening this predicate invents missing linked starts.
        if location_type == 6:
            linked_location_packages.add(package_id)
        if location_type == 0:
            refs.append(canonical(location.get("location")))
            explicit_reference_rows += 1
        if int(target.get("type", -1)) == 0:
            refs.append(canonical(target.get("target")))
            explicit_reference_rows += 1
        refs = [value for value in refs if value]
        requested_targets.update(refs)
        if refs:
            package_targets[package_id] = refs
    requested_targets.discard("")

    doors: dict[str, dict] = {}
    targets: dict[str, dict] = {}
    placements_by_ref: dict[str, dict] = {}
    cell_edges: defaultdict[str, list[str]] = defaultdict(list)
    shards = {}
    for cell in [*runtime.get("cells", []), *runtime.get("interiors", [])]:
        shard = Path(str(cell.get("shard", "")))
        if shard:
            shards[str(shard.resolve())] = (canonical(cell.get("form_id")), shard)
    placement_count = 0
    for cell_id, shard in shards.values():
        document = json.loads(shard.read_text(encoding="utf-8"))
        for placement in document.get("placements", []):
            placement_count += 1
            ref_id = canonical(placement.get("form_id"))
            if not ref_id or ref_id in placements_by_ref:
                raise SystemExit(f"missing or duplicate placed reference {ref_id or '<empty>'}")
            placements_by_ref[ref_id] = {
                "cell": cell_id,
                "position": placement.get("position"),
                "baseType": placement.get("base_type", ""),
                "defaultEnabled": bool(placement.get("default_enabled", True)),
                "enableParent": canonical(placement.get("enable_parent")),
                "enableParentFlags": int(placement.get("enable_parent_flags", 0) or 0),
                "linkedReference": canonical(placement.get("linked_reference")),
            }
            if ref_id in requested_targets:
                targets[ref_id] = dict(placements_by_ref[ref_id])
            destination_cell = canonical(placement.get("destination_cell"))
            destination_door = canonical(placement.get("destination_door"))
            if placement.get("base_type") != "DOOR" or not destination_cell or not destination_door:
                continue
            doors[ref_id] = {
                "sourceCell": cell_id,
                "destinationCell": destination_cell,
                "destinationDoor": destination_door,
                "position": placement.get("position"),
                "defaultEnabled": bool(placement.get("default_enabled", True)),
                "locked": bool(placement.get("locked", False)),
                "lockLevel": int(placement.get("lock_level", 0) or 0),
                "enableParent": canonical(placement.get("enable_parent")),
                "enableParentFlags": int(placement.get("enable_parent_flags", 0) or 0),
            }
            cell_edges[cell_id].append(ref_id)

    missing_endpoints = [
        {"door": door_id, "destinationDoor": row["destinationDoor"]}
        for door_id, row in doors.items() if row["destinationDoor"] not in doors
    ]
    # The player reference is intentionally not an authored world placement in
    # the runtime shards. It is a first-class live runtime target, not missing
    # content, and must stay separate from static placement resolution.
    runtime_targets = {
        "0x00000014": {"kind": "player", "resolver": "live-player-transform"}
    }
    runtime_targets = {
        key: value for key, value in runtime_targets.items() if key in requested_targets
    }
    unresolved_targets = sorted(requested_targets - targets.keys() - runtime_targets.keys())
    linked_source_ids = {
        ref_id for ref_id, row in placements_by_ref.items() if row["linkedReference"]
    }
    linked_node_ids = linked_source_ids | {
        placements_by_ref[ref_id]["linkedReference"] for ref_id in linked_source_ids
    }
    linked_references = {
        ref_id: placements_by_ref[ref_id]
        for ref_id in sorted(linked_node_ids) if ref_id in placements_by_ref
    }
    missing_linked_endpoints = sorted(linked_node_ids - placements_by_ref.keys())
    cross_cell_linked_edges = sum(
        1 for ref_id in linked_source_ids
        if placements_by_ref[ref_id]["linkedReference"] in placements_by_ref
        and placements_by_ref[ref_id]["cell"] != placements_by_ref[placements_by_ref[ref_id]["linkedReference"]]["cell"]
    )
    linked_cycle_nodes: set[str] = set()
    linked_cycle_count = 0
    visited_link_nodes: set[str] = set()
    for start in sorted(linked_source_ids):
        if start in visited_link_nodes:
            continue
        order: list[str] = []
        offsets: dict[str, int] = {}
        current = start
        while current in linked_references and current not in visited_link_nodes:
            if current in offsets:
                cycle = order[offsets[current]:]
                linked_cycle_nodes.update(cycle)
                linked_cycle_count += 1
                break
            offsets[current] = len(order)
            order.append(current)
            current = canonical(linked_references[current].get("linkedReference"))
            if not current:
                break
        visited_link_nodes.update(order)
    accessible_adjacency: defaultdict[str, list[str]] = defaultdict(list)
    weak_adjacency: defaultdict[str, set[str]] = defaultdict(set)
    for row in doors.values():
        if (not row["defaultEnabled"] or row["locked"] or row["lockLevel"] > 0
                or row["enableParent"]):
            continue
        source_cell = row["sourceCell"]
        destination_cell = row["destinationCell"]
        accessible_adjacency[source_cell].append(destination_cell)
        weak_adjacency[source_cell].add(destination_cell)
        weak_adjacency[destination_cell].add(source_cell)

    remaining_component_cells = set(weak_adjacency)
    component_sizes: list[int] = []
    while remaining_component_cells:
        start = next(iter(remaining_component_cells))
        queue = deque([start])
        remaining_component_cells.remove(start)
        size = 0
        while queue:
            cell = queue.popleft()
            size += 1
            for neighbor in weak_adjacency[cell]:
                if neighbor in remaining_component_cells:
                    remaining_component_cells.remove(neighbor)
                    queue.append(neighbor)
        component_sizes.append(size)

    blueprint_packages = {
        canonical(row.get("id")): [canonical(value) for value in row.get("packages", [])]
        for row in blueprints_doc.get("blueprints", [])
    }
    reachability_cache: dict[tuple[str, str], bool] = {}

    def door_reachable(source: str, destination: str) -> bool:
        if source == destination:
            return True
        key = (source, destination)
        if key in reachability_cache:
            return reachability_cache[key]
        queue = deque([source])
        visited = {source}
        while queue:
            cell = queue.popleft()
            for neighbor in accessible_adjacency.get(cell, []):
                if neighbor == destination:
                    reachability_cache[key] = True
                    return True
                if neighbor not in visited:
                    visited.add(neighbor)
                    queue.append(neighbor)
        reachability_cache[key] = False
        return False

    population_package_applications = 0
    population_explicit_target_applications = 0
    population_same_cell_target_applications = 0
    population_door_graph_reachable_applications = 0
    population_runtime_target_applications = 0
    population_unreachable_static_applications = 0
    population_linked_location_applications = 0
    population_linked_location_starts = 0
    population_linked_location_missing_starts = 0
    linked_location_applications: list[dict] = []
    for placement in blueprints_doc.get("population", []):
        placement_ref = canonical(placement.get("reference"))
        source_cell = canonical(placement.get("cell"))
        for package_id in blueprint_packages.get(canonical(placement.get("base")), []):
            population_package_applications += 1
            if package_id in linked_location_packages:
                population_linked_location_applications += 1
                linked_start = canonical(placements_by_ref.get(placement_ref, {}).get("linkedReference"))
                linked_location_applications.append({
                    "actorRef": placement_ref,
                    "actorBase": canonical(placement.get("base")),
                    "actorCell": source_cell,
                    "packageId": package_id,
                    **package_semantics[package_id],
                    "seedRef": linked_start,
                    "resolved": bool(linked_start and linked_start in linked_references),
                })
                if linked_start and linked_start in linked_references:
                    population_linked_location_starts += 1
                else:
                    population_linked_location_missing_starts += 1
            for target_id in package_targets.get(package_id, []):
                population_explicit_target_applications += 1
                if target_id in runtime_targets:
                    population_runtime_target_applications += 1
                    continue
                target_cell = canonical(targets.get(target_id, {}).get("cell"))
                if source_cell == target_cell and source_cell:
                    population_same_cell_target_applications += 1
                elif source_cell and target_cell and door_reachable(source_cell, target_cell):
                    population_door_graph_reachable_applications += 1
                else:
                    population_unreachable_static_applications += 1

    locked_or_conditional_doors = sum(
        1 for row in doors.values()
        if (not row["defaultEnabled"] or row["locked"] or row["lockLevel"] > 0
            or row["enableParent"])
    )
    unavailable_default_targets = sum(
        1 for row in targets.values()
        if not row["defaultEnabled"] or row["enableParent"]
    )
    result = {
        "schema": "opennv-package-navigation-index/v1",
        "semanticContract": "linked-location-type6-only/v1",
        "status": "pass" if not missing_endpoints and not unresolved_targets and not missing_linked_endpoints else "fail",
        "provenance": {
            "runtimeIndexSha256": sha256(args.runtime_index),
            "packagesSha256": sha256(args.packages),
            "blueprintsSha256": sha256(args.blueprints),
            "loadOrderSha256": runtime.get("load_order_sha256", ""),
            "compilerSha256": sha256(Path(__file__)),
        },
        "counts": {
            "shards": len(shards), "placements": placement_count,
            "doors": len(doors), "cellEdges": sum(map(len, cell_edges.values())),
            "packageReferenceTargets": len(requested_targets),
            "resolvedPackageReferenceTargets": len(targets),
            "runtimeResolvedPackageReferenceTargets": len(runtime_targets),
            "unresolvedPackageReferenceTargets": len(unresolved_targets),
            "missingDoorEndpoints": len(missing_endpoints),
            "explicitReferenceRows": explicit_reference_rows,
            "packagesWithExplicitReferences": len(package_targets),
            "lockedConditionalOrDisabledDoors": locked_or_conditional_doors,
            "defaultUnavailableReferenceTargets": unavailable_default_targets,
            "defaultAccessibleDoorGraphCells": len(weak_adjacency),
            "defaultAccessibleDoorGraphComponents": len(component_sizes),
            "largestDefaultAccessibleDoorGraphComponent": max(component_sizes, default=0),
            "populationPackageApplications": population_package_applications,
            "populationExplicitTargetApplications": population_explicit_target_applications,
            "populationSameCellTargetApplications": population_same_cell_target_applications,
            "populationDoorGraphReachableApplications": population_door_graph_reachable_applications,
            "populationRuntimeTargetApplications": population_runtime_target_applications,
            "populationUnreachableStaticApplications": population_unreachable_static_applications,
            "linkedReferenceSources": len(linked_source_ids),
            "linkedReferenceNodes": len(linked_references),
            "missingLinkedReferenceEndpoints": len(missing_linked_endpoints),
            "crossCellLinkedReferenceEdges": cross_cell_linked_edges,
            "linkedReferenceCycles": linked_cycle_count,
            "linkedReferenceCycleNodes": len(linked_cycle_nodes),
            "linkedLocationPackages": len(linked_location_packages),
            "populationLinkedLocationApplications": population_linked_location_applications,
            "populationLinkedLocationResolvedStarts": population_linked_location_starts,
            "populationLinkedLocationMissingStarts": population_linked_location_missing_starts,
        },
        "coverageTier": "explicit-and-linked-reference-endpoint-integrity; door-only reachability is partial",
        "doors": doors,
        "cellEdges": {cell: sorted(values) for cell, values in sorted(cell_edges.items())},
        "targets": targets,
        "linkedReferences": linked_references,
        "linkedLocationApplications": sorted(
            linked_location_applications,
            key=lambda row: (row["actorRef"], row["packageId"]),
        ),
        "runtimeTargets": runtime_targets,
        "unresolvedTargets": unresolved_targets,
        "missingDoorEndpoints": missing_endpoints,
        "missingLinkedReferenceEndpoints": missing_linked_endpoints,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(",", ":")) + "\n", encoding="utf-8")
    print("OPENNV_PACKAGE_NAVIGATION_INDEX " + json.dumps(result["counts"], sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
