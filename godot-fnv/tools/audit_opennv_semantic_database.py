#!/usr/bin/env python3
"""Verify semantic database integrity and cross-record runtime coverage."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


PLACED_TYPES = ("REFR", "ACHR", "ACRE", "PGRE", "PHZD")


def _sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def audit(semantic_dir: Path, resolved_manifest_path: Path) -> dict:
    manifest_path = semantic_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    resolved = json.loads(resolved_manifest_path.read_text(encoding="utf-8"))
    artifact_errors = []
    for artifact in manifest.get("artifacts", []):
        path = semantic_dir / artifact["path"]
        if not path.is_file():
            artifact_errors.append({"path": artifact["path"], "error": "missing"})
            continue
        if path.stat().st_size != artifact["bytes"] or _sha(path) != artifact["sha256"]:
            artifact_errors.append({"path": artifact["path"], "error": "digest-or-size"})

    actor_bases = json.loads((semantic_dir / "actor-bases.json").read_text(encoding="utf-8"))["actors"]
    actor_ids = {row["id"] for row in actor_bases}
    cell_ids = {row["id"] for row in json.loads((semantic_dir / "cells.json").read_text(encoding="utf-8"))["cells"]}
    placement_ids = set()
    actor_placements = 0
    direct_actor_bases = 0
    levelled_actor_bases = 0
    missing_actor_bases = []
    missing_parent_cells = []
    linked_doors = 0
    destination_ids = []
    placement_count = 0
    for shard in sorted((semantic_dir / "placements").glob("*.json")):
        rows = json.loads(shard.read_text(encoding="utf-8"))["placements"]
        for row in rows:
            placement_count += 1
            placement_ids.add(row["id"])
            parent = row.get("parentCell")
            if parent and parent not in cell_ids:
                missing_parent_cells.append(row["id"])
            spatial = row.get("spatialCell")
            if spatial and spatial not in cell_ids:
                missing_parent_cells.append(row["id"] + ":spatial")
            if row.get("destDoor"):
                linked_doors += 1
                destination_ids.append(row["destDoor"])
            if row.get("type") not in ("ACHR", "ACRE"):
                continue
            actor_placements += 1
            base = row.get("base")
            base_type = row.get("baseType")
            if base in actor_ids:
                direct_actor_bases += 1
            elif base_type in ("LVLN", "LVLC"):
                levelled_actor_bases += 1
            else:
                missing_actor_bases.append(row["id"])
    unresolved_destinations = sorted(set(destination_ids) - placement_ids)

    base_types = {row["id"]: row["type"] for row in actor_bases}
    missing_templates = []
    cross_type_templates = []
    for row in actor_bases:
        template = row.get("baseTemplate")
        if not template:
            continue
        target_type = base_types.get(template)
        if target_type is None:
            # A levelled template is valid but is resolved by the LVLN/LVLC compiler.
            continue
        if target_type != row["type"]:
            cross_type_templates.append({"actor": row["id"], "template": template})

    types = resolved["types"]
    expected = {
        "live_records": resolved["counts"]["live"],
        "worlds": types["WRLD"]["live"],
        "cells": types["CELL"]["live"],
        "placements": sum(types.get(name, {}).get("live", 0) for name in PLACED_TYPES),
        "actor_bases": types["NPC_"]["live"] + types["CREA"]["live"],
        "actor_placements": types["ACHR"]["live"] + types["ACRE"]["live"],
        "scripts": types["SCPT"]["live"],
    }
    observed = dict(manifest["counts"])
    denominator_mismatches = {
        key: {"expected": value, "observed": observed.get(key)}
        for key, value in expected.items() if observed.get(key) != value
    }
    hard_failures = bool(
        artifact_errors or denominator_mismatches or missing_parent_cells
        or missing_actor_bases or cross_type_templates
        or int(observed.get("unresolved_exterior_spatial_cells", -1)) != 0
    )
    # Unresolved door endpoints remain a parity failure even though some are
    # authored across absent/non-winning references; every runtime edge must be
    # explicitly classified before promotion.
    parity_failures = hard_failures or bool(unresolved_destinations)
    return {
        "schema": "opennv-semantic-database-audit/v1",
        "status": "fail" if parity_failures else "pass",
        "semantic_manifest_sha256": _sha(manifest_path),
        "resolved_manifest_sha256": _sha(resolved_manifest_path),
        "expected": expected,
        "observed": observed,
        "artifact_errors": artifact_errors,
        "denominator_mismatches": denominator_mismatches,
        "cross_links": {
            "actor_placements": actor_placements,
            "direct_actor_bases": direct_actor_bases,
            "levelled_actor_bases": levelled_actor_bases,
            "missing_actor_bases": len(missing_actor_bases),
            "missing_parent_cells": len(missing_parent_cells),
            "linked_doors": linked_doors,
            "unresolved_door_destinations": len(unresolved_destinations),
            "cross_type_templates": len(cross_type_templates),
        },
        "missing_actor_base_refs": missing_actor_bases,
        "missing_parent_cell_refs": missing_parent_cells,
        "unresolved_door_destination_refs": unresolved_destinations,
        "cross_type_template_refs": cross_type_templates,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--semantic-dir", type=Path, required=True)
    parser.add_argument("--resolved-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()
    result = audit(args.semantic_dir.resolve(), args.resolved_manifest.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_SEMANTIC_AUDIT " + json.dumps(result["cross_links"], sort_keys=True))
    return 0 if result["status"] == "pass" or args.allow_incomplete else 1


if __name__ == "__main__":
    raise SystemExit(main())
