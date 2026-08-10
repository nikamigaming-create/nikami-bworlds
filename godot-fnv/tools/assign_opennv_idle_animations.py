#!/usr/bin/env python3
"""Attach shared retail idle clips to compatible resolved actor assemblies."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


HUMANOID = "res://generated/animations/authored-v1/humanoid-mtidle.onvanim"
SECURITRON = "res://generated/animations/authored-v1/securitron-mtidle.onvanim"
SECURITRON_PATTERN = re.compile(r"securitron|victor|yesman|yes-man|muggy", re.I)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    project_root = args.project_root.resolve()
    resources = {"humanoid": HUMANOID, "securitron": SECURITRON}
    hashes: dict[str, str] = {}
    for key, resource in resources.items():
        path = project_root / resource.removeprefix("res://")
        if not path.is_file():
            raise FileNotFoundError(path)
        hashes[key] = sha256(path)
    counts = {"humanoid": 0, "securitron": 0, "unassigned": 0}
    for actor in manifest.get("actors", []):
        actor.pop("animation_idle", None)
        actor.pop("animation_idle_sha256", None)
        if SECURITRON_PATTERN.search(str(actor.get("id", ""))):
            key = "securitron"
        elif "humanoid" in str(actor.get("category", "")).lower():
            key = "humanoid"
        else:
            counts["unassigned"] += 1
            continue
        actor["animation_idle"] = resources[key]
        actor["animation_idle_sha256"] = hashes[key]
        counts[key] += 1
    manifest["idle_animation_assignment"] = {
        "schema": "opennv-idle-animation-assignment/v1",
        "counts": counts,
        "resources": {key: {"path": value, "sha256": hashes[key]} for key, value in resources.items()},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_IDLE_ANIMATIONS_ASSIGNED " + json.dumps(counts, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
