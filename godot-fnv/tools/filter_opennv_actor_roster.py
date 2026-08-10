#!/usr/bin/env python3
"""Select roster actors that do not yet have exact entries in a Godot manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def canonical(value: object) -> str:
    return f"0x{int(str(value), 16):08x}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--roster", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--unique-missing-base",
        action="store_true",
        help="Emit one representative reference for every base absent from the manifest.",
    )
    args = parser.parse_args()
    roster = json.loads(args.roster.read_text(encoding="utf-8"))
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    cached = {canonical(row["authored_ref"]) for row in manifest.get("actors", [])}
    cached_bases = {canonical(row["base_form"]) for row in manifest.get("actors", [])}
    targets = []
    selected_bases: set[str] = set()
    for row in roster.get("targets", []):
        reference = canonical(row["authoredRef"])
        base = canonical(row["base"])
        if args.unique_missing_base:
            if base in cached_bases or base in selected_bases:
                continue
            selected_bases.add(base)
        elif reference in cached:
            continue
        targets.append(row)
    result = {
        "schema": "nikami-fnv-actor-roster/v1",
        "sourceRoster": str(args.roster.resolve()),
        "excludedManifest": str(args.manifest.resolve()),
        "selection": "unique-missing-base" if args.unique_missing_base else "missing-authored-reference",
        "targetCount": len(targets),
        "targets": targets,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"OPENNV_FILTERED_ACTOR_ROSTER count={len(targets)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
