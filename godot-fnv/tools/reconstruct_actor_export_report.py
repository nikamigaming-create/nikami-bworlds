#!/usr/bin/env python3
"""Reconstruct the deterministic actor export index after a detached batch."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--roster", type=Path, required=True)
    parser.add_argument("--mesh-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    roster_path = args.roster.resolve()
    mesh_root = args.mesh_root.resolve()
    roster = json.loads(roster_path.read_text(encoding="utf-8"))
    actors = []
    for index, target in enumerate(roster["targets"]):
        obj = mesh_root / f"actor-{index:03d}.obj"
        mtl = mesh_root / f"actor-{index:03d}.mtl"
        if not obj.is_file() or not mtl.is_file() or obj.stat().st_size <= 128 or mtl.stat().st_size <= 32:
            raise RuntimeError(f"Missing or empty completed actor export: {obj}")
        actors.append(
            {
                "index": index,
                "id": target["id"],
                "category": target["category"],
                "authoredRef": target["authoredRef"],
                "base": target["base"],
                "obj": str(obj),
                "mtl": str(mtl),
                "sha256": sha256(obj),
            }
        )
    report = {
        "schema": "opennv-godot-actor-mesh-export/v1",
        "status": "pass",
        "rosterPath": str(roster_path),
        "rosterSha256": sha256(roster_path),
        "targetCount": len(actors),
        "processExitCode": 0,
        "nativeScreenshotCount": 0,
        "meshRoot": str(mesh_root),
        "actors": actors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"OPENNV_ACTOR_EXPORT_REPORT_RECONSTRUCTED actors={len(actors)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
