#!/usr/bin/env python3
"""Fail closed on silent OpenNV world, actor, door, and structural omissions."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ACTOR_TYPES = {"NPC_", "CREA"}
STRUCTURAL_PREFIXES = ("architecture\\", "dungeons\\", "scol\\")
INTENTIONALLY_NONSTATIC = ("effects\\", "fx\\", "marker", "characters\\", "creatures\\")


def canonical_form(value: object) -> str:
    text = str(value or "").lower()
    return f"0x{int(text, 16):08x}" if text.startswith("0x") else text


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def materialize(index: dict, project_root: Path) -> dict:
    shard = str(index.get("shard", ""))
    if not shard:
        return index
    path = project_root / shard.removeprefix("res://")
    if not path.is_file():
        raise RuntimeError(f"missing shard: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ring", type=Path, required=True)
    parser.add_argument("--actor-manifest", type=Path, required=True)
    parser.add_argument("--project-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()

    ring_path = args.ring.resolve()
    project_root = (args.project_root or ring_path.parents[2]).resolve()
    ring = json.loads(ring_path.read_text(encoding="utf-8"))
    manifest = json.loads(args.actor_manifest.read_text(encoding="utf-8"))
    actor_refs = {canonical_form(row.get("authored_ref")) for row in manifest.get("actors", [])}
    actor_bases = {canonical_form(row.get("base_form")) for row in manifest.get("actors", [])}

    placements: list[dict] = []
    cells: list[dict] = []
    for index in [*ring.get("cells", []), *ring.get("interiors", [])]:
        cell = materialize(index, project_root)
        cells.append(cell)
        placements.extend(cell.get("placements", []))

    all_refs = {canonical_form(row.get("form_id")) for row in placements}
    actors = [row for row in placements if row.get("base_type") in ACTOR_TYPES]
    exact_actor_refs = {canonical_form(row.get("form_id")) for row in actors if canonical_form(row.get("form_id")) in actor_refs}
    base_fallback_refs = {
        canonical_form(row.get("form_id")) for row in actors
        if canonical_form(row.get("form_id")) not in actor_refs
        and canonical_form(row.get("base_form_id")) in actor_bases
    }
    missing_actors = sorted(
        canonical_form(row.get("form_id")) for row in actors
        if canonical_form(row.get("form_id")) not in exact_actor_refs | base_fallback_refs
    )

    linked_doors = [row for row in placements if row.get("base_type") == "DOOR" and row.get("destination_door")]
    unresolved_doors = sorted(
        canonical_form(row.get("form_id")) for row in linked_doors
        if canonical_form(row.get("destination_door")) not in all_refs
    )

    converted_root = project_root / "generated" / "assets" / "converted"
    required_models: set[str] = set()
    missing_structural: set[str] = set()
    missing_nonstructural: set[str] = set()
    for row in placements:
        model = str(row.get("model", "")).lower().replace("/", "\\")
        if not model.endswith(".nif") or model.startswith(INTENTIONALLY_NONSTATIC):
            continue
        output = converted_root / Path(model[:-4].replace("\\", "/") + ".obj")
        if model.startswith(STRUCTURAL_PREFIXES):
            required_models.add(model)
            if not output.is_file():
                missing_structural.add(model)
        elif not output.is_file():
            missing_nonstructural.add(model)

    report = {
        "schema": "opennv-content-coverage/v1",
        "status": "pass" if not missing_actors and not unresolved_doors and not missing_structural else "fail",
        "ring": {"path": str(ring_path), "sha256": digest(ring_path)},
        "actor_manifest": {"path": str(args.actor_manifest.resolve()), "sha256": digest(args.actor_manifest.resolve())},
        "counts": {
            "cells": len(cells),
            "placements": len(placements),
            "actors": len(actors),
            "actor_exact": len(exact_actor_refs),
            "actor_base_fallback": len(base_fallback_refs),
            "actor_missing": len(missing_actors),
            "linked_doors": len(linked_doors),
            "unresolved_doors": len(unresolved_doors),
            "required_structural_models": len(required_models),
            "missing_structural_models": len(missing_structural),
            "missing_nonstructural_models": len(missing_nonstructural),
        },
        "missing_actor_refs": missing_actors,
        "unresolved_door_refs": unresolved_doors,
        "missing_structural_models": sorted(missing_structural),
        "missing_nonstructural_models": sorted(missing_nonstructural),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_CONTENT_COVERAGE " + json.dumps(report["counts"], sort_keys=True))
    print(f"OPENNV_CONTENT_COVERAGE_STATUS {report['status']} report={args.output}")
    return 0 if report["status"] == "pass" or args.allow_incomplete else 2


if __name__ == "__main__":
    raise SystemExit(main())
