#!/usr/bin/env python3
"""Conserve the full enabled actor denominator through exact/base visual resolution."""

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
    args = parser.parse_args()
    roster = json.loads(args.roster.read_text(encoding="utf-8"))
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    refs = {canonical(row["authored_ref"]) for row in manifest.get("actors", [])}
    bases = {canonical(row["base_form"]) for row in manifest.get("actors", [])}
    exact: list[str] = []
    base_resolved: list[str] = []
    missing: list[str] = []
    seen: set[str] = set()
    duplicates: list[str] = []
    for row in roster.get("targets", []):
        ref = canonical(row["authoredRef"])
        base = canonical(row["base"])
        if ref in seen:
            duplicates.append(ref)
        seen.add(ref)
        if ref in refs:
            exact.append(ref)
        elif base in bases:
            base_resolved.append(ref)
        else:
            missing.append(ref)
    counts = {
        "enabled_references": len(seen),
        "exact_references": len(exact),
        "base_resolved_references": len(base_resolved),
        "missing_references": len(missing),
        "duplicate_roster_references": len(set(duplicates)),
        "manifest_references": len(refs),
        "manifest_bases": len(bases),
    }
    status = "pass" if not missing and not duplicates and len(seen) == int(roster["targetCount"]) else "fail"
    report = {
        "schema": "opennv-full-actor-resolution/v1",
        "status": status,
        "counts": counts,
        "missing_references": missing,
        "duplicate_roster_references": sorted(set(duplicates)),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_FULL_ACTOR_RESOLUTION " + json.dumps(counts, sort_keys=True))
    return 0 if status == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
