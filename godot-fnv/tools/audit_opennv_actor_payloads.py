#!/usr/bin/env python3
"""Validate every promoted ONVSKEL payload outside the latency-sensitive runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from concurrent.futures import ProcessPoolExecutor
from functools import partial
from pathlib import Path

from decode_opennv_skeletal_actor import DecodeError, decode_bytes


def resolve_resource(path: str, project_root: Path) -> Path:
    return project_root / path.removeprefix("res://") if path.startswith("res://") else Path(path)


def validate(row: tuple[str, str], project_root: Path) -> dict[str, object] | None:
    resource, expected = row
    path = resolve_resource(resource, project_root)
    if not path.is_file():
        return {"path": resource, "reason": "missing"}
    data = path.read_bytes()
    try:
        audit = decode_bytes(data)
    except DecodeError as error:
        return {"path": resource, "reason": "invalid-payload", "detail": str(error)}
    if audit["surface_count"] < 1:
        return {"path": resource, "reason": "empty-payload", "version": audit["format_version"]}
    if audit["format_version"] >= 2 and (
        audit["canonical_bone_count"] < 1 or audit["canonical_hierarchy_max_residual"] > 1e-4
    ):
        return {"path": resource, "reason": "invalid-canonical-skeleton"}
    digest = hashlib.sha256(data).hexdigest()
    if not expected or digest != expected:
        return {"path": resource, "reason": "sha256-mismatch", "expected": expected, "actual": digest}
    return None


def validate_animation(row: tuple[str, str], project_root: Path) -> dict[str, object] | None:
    resource, expected = row
    path = resolve_resource(resource, project_root)
    if not path.is_file():
        return {"path": resource, "reason": "missing-animation"}
    data = path.read_bytes()
    if len(data) < 28 or data[:8] != b"ONVANIM1":
        return {"path": resource, "reason": "invalid-animation-header"}
    digest = hashlib.sha256(data).hexdigest()
    if not expected or digest != expected:
        return {"path": resource, "reason": "animation-sha256-mismatch", "expected": expected, "actual": digest}
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    project_root = args.project_root.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    payloads: dict[str, str] = {}
    conflicting_hashes: list[str] = []
    animations: dict[str, str] = {}
    for actor in manifest.get("actors", []):
        resource = str(actor.get("skeletal", "")).strip()
        if not resource:
            continue
        expected = str(actor.get("skeletal_sha256", "")).strip().lower()
        if resource in payloads and payloads[resource] != expected:
            conflicting_hashes.append(resource)
        payloads[resource] = expected
        animation = str(actor.get("animation_idle", "")).strip()
        if animation:
            animations[animation] = str(actor.get("animation_idle_sha256", "")).strip().lower()
    rows = sorted(payloads.items())
    # Payload decoding is CPU-bound Python work. Threads serialize on the GIL
    # and made a full 5k-actor census effectively single-core; process workers
    # retain deterministic map order while using the requested machine budget.
    with ProcessPoolExecutor(max_workers=max(1, args.workers)) as executor:
        failures = [result for result in executor.map(
            partial(validate, project_root=project_root), rows) if result]
        failures.extend(result for result in executor.map(
            partial(validate_animation, project_root=project_root), sorted(animations.items())) if result)
    failures.extend({"path": path, "reason": "conflicting-manifest-hash"} for path in sorted(set(conflicting_hashes)))
    report = {
        "schema": "opennv-actor-payload-audit/v2",
        "status": "pass" if not failures else "fail",
        "manifest": str(manifest_path),
        "counts": {"actors": len(manifest.get("actors", [])), "skeletal_payloads": len(rows),
                   "animation_payloads": len(animations), "failures": len(failures)},
        "failures": failures,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_ACTOR_PAYLOAD_AUDIT " + json.dumps(report["counts"], sort_keys=True))
    print(f"OPENNV_ACTOR_PAYLOAD_AUDIT_STATUS {report['status']} report={args.output}")
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
