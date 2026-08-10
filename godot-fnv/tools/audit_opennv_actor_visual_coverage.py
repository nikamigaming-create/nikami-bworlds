#!/usr/bin/env python3
"""Require one exact cached visual for every enabled actor in a sharded runtime ring."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ACTOR_TYPES = {"NPC_", "CREA"}


def canonical_form(value: object) -> str:
    text = str(value or "").strip().lower()
    if not text:
        return ""
    return f"0x{int(text, 16):08x}" if text.startswith("0x") else text


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def materialize(entry: dict, project_root: Path) -> dict:
    shard = str(entry.get("shard", ""))
    if not shard:
        return entry
    path = project_root / shard.removeprefix("res://") if shard.startswith("res://") else Path(shard)
    if not path.is_file():
        raise RuntimeError(f"missing runtime-ring shard: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ring", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    ring_path = args.ring.resolve()
    manifest_path = args.manifest.resolve()
    project_root = (args.project_root or ring_path.parents[2]).resolve()
    ring = json.loads(ring_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    cached_refs = {
        canonical_form(row.get("authored_ref"))
        for row in manifest.get("actors", [])
        if canonical_form(row.get("authored_ref"))
    }
    enabled_refs: set[str] = set()
    disabled_refs: set[str] = set()
    duplicate_refs: set[str] = set()
    seen_refs: set[str] = set()
    for entry in [*ring.get("cells", []), *ring.get("interiors", [])]:
        cell = materialize(entry, project_root)
        for placement in cell.get("placements", []):
            if placement.get("base_type") not in ACTOR_TYPES:
                continue
            ref = canonical_form(placement.get("form_id"))
            if not ref:
                continue
            if ref in seen_refs:
                duplicate_refs.add(ref)
            seen_refs.add(ref)
            if placement.get("default_enabled", True) is False:
                disabled_refs.add(ref)
            else:
                enabled_refs.add(ref)

    exact_refs = enabled_refs & cached_refs
    missing_refs = sorted(enabled_refs - cached_refs)
    report = {
        "schema": "opennv-actor-visual-coverage/v1",
        "status": "pass" if not missing_refs and not duplicate_refs else "fail",
        "ring": {"path": str(ring_path), "sha256": sha256(ring_path)},
        "manifest": {"path": str(manifest_path), "sha256": sha256(manifest_path)},
        "counts": {
            "enabled_authored_refs": len(enabled_refs),
            "disabled_authored_refs": len(disabled_refs),
            "exact_cached_refs": len(exact_refs),
            "missing_enabled_refs": len(missing_refs),
            "duplicate_ring_refs": len(duplicate_refs),
            "manifest_refs": len(cached_refs),
        },
        "missing_enabled_refs": missing_refs,
        "duplicate_ring_refs": sorted(duplicate_refs),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_ACTOR_VISUAL_COVERAGE " + json.dumps(report["counts"], sort_keys=True))
    print(f"OPENNV_ACTOR_VISUAL_COVERAGE_STATUS {report['status']} report={args.output}")
    return 0 if report["status"] == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
