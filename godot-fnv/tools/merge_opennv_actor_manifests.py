#!/usr/bin/env python3
"""Merge independently exported OpenNV actor chunks into one Godot cache."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--roster", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-duplicate-refs", action="store_true")
    parser.add_argument("--require-skeletal", action="store_true")
    parser.add_argument("manifests", nargs="+", type=Path)
    args = parser.parse_args()

    roster_bytes = args.roster.read_bytes()
    roster = json.loads(roster_bytes)
    expected_refs = [str(item["authoredRef"]).lower() for item in roster["targets"]]
    by_ref: dict[str, dict] = {}
    texture_count = 0
    sources: list[str] = []
    for path in args.manifests:
        document = json.loads(path.read_text(encoding="utf-8"))
        if document.get("status") != "pass":
            raise RuntimeError(f"Actor chunk did not pass: {path}")
        sources.append(str(path.resolve()))
        texture_count += int(document.get("texture_count", 0))
        for actor in document.get("actors", []):
            ref = str(actor["authored_ref"]).lower()
            # A prior corridor cache may contain actors that are outside the
            # replacement route.  Ignore those entries while retaining strict
            # one-to-one coverage for every actor in the requested roster.
            if ref not in expected_refs:
                continue
            if ref in by_ref:
                if args.allow_duplicate_refs:
                    continue
                raise RuntimeError(f"Duplicate authored actor reference: {ref}")
            by_ref[ref] = actor

    missing = [ref for ref in expected_refs if ref not in by_ref]
    if missing:
        raise RuntimeError(f"Actor manifest coverage mismatch: missing={missing}")

    actors = []
    for index, ref in enumerate(expected_refs):
        actor = dict(by_ref[ref])
        actor["index"] = index
        if args.require_skeletal and not actor.get("skeletal"):
            raise RuntimeError(f"Actor is missing lossless skeletal payload: {ref}")
        actors.append(actor)
    skeletal_count = sum(1 for actor in actors if actor.get("skeletal"))
    output = {
        "schema": "opennv-godot-actor-cache/v2" if skeletal_count == len(actors) else "opennv-godot-actor-cache/v1",
        "status": "pass",
        "source_manifests": sources,
        "roster_sha256": hashlib.sha256(roster_bytes).hexdigest(),
        "actor_count": len(actors),
        "texture_reference_count": texture_count,
        "native_screenshot_count": 0,
        "skeletal_actor_count": skeletal_count,
        "coordinate_transform": "inverse-common-staging-yaw; bethesda-z-up-to-godot-y-up",
        "actors": actors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(f"OPENNV_GODOT_ACTOR_MANIFEST_MERGED actors={len(actors)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
