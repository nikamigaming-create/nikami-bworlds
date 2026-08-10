#!/usr/bin/env python3
"""Merge authored-reference actor rosters without allowing one scene to evict another."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("rosters", nargs="+", type=Path)
    args = parser.parse_args()
    by_ref: dict[int, dict] = {}
    sources: list[str] = []
    for path in args.rosters:
        document = json.loads(path.read_text(encoding="utf-8"))
        sources.append(str(path.resolve()))
        for target in document.get("targets", []):
            by_ref.setdefault(int(str(target["authoredRef"]), 16), target)
    targets = [by_ref[key] for key in sorted(by_ref)]
    result = {
        "schema": "nikami-fnv-actor-roster/v1",
        "source_rosters": sources,
        "targetCount": len(targets),
        "targets": targets,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"OPENNV_ACTOR_ROSTERS_MERGED count={len(targets)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
