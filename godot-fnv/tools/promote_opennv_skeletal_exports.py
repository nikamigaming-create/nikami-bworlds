#!/usr/bin/env python3
"""Promote validated OpenNV skeletal payloads into a Godot actor manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from decode_opennv_skeletal_actor import decode_bytes


def canonical(value: str) -> str:
    return f"0x{int(value, 16):08x}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--roster", type=Path, required=True)
    parser.add_argument("--payload-root", type=Path, required=True)
    parser.add_argument("--base-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--target-id", action="append", default=[])
    parser.add_argument("--export-report", type=Path)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    roster = json.loads(args.roster.read_text(encoding="utf-8"))
    selected = [row for row in roster["targets"] if not args.target_id or row["id"] in args.target_id]
    if not selected:
        raise RuntimeError("No roster targets selected for skeletal promotion")
    payloads = sorted(args.payload_root.resolve().glob("actor-*.onvskel"))
    if len(payloads) != len(selected):
        raise RuntimeError(f"Skeletal payload/roster mismatch: payloads={len(payloads)} targets={len(selected)}")
    export_report = None
    if args.export_report:
        export_report = json.loads(args.export_report.read_text(encoding="utf-8"))
        report_actors = export_report.get("actors", [])
        if export_report.get("status") != "pass" or export_report.get("nativeScreenshotCount") != 0:
            raise RuntimeError("Skeletal export report did not pass its no-screenshot gate")
        if len(report_actors) != len(selected):
            raise RuntimeError("Skeletal export report target count does not match selected roster")
        for index, (target, report_actor, payload) in enumerate(zip(selected, report_actors, payloads, strict=True)):
            if int(report_actor.get("index", -1)) != index or report_actor.get("id") != target["id"]:
                raise RuntimeError(f"Skeletal export report identity mismatch at index {index}")
            if canonical(report_actor["authoredRef"]) != canonical(target["authoredRef"]):
                raise RuntimeError(f"Skeletal export report reference mismatch at index {index}")
            if Path(report_actor["skeletal"]).resolve() != payload.resolve():
                raise RuntimeError(f"Skeletal export report payload mismatch at index {index}")
            payload_hash = hashlib.sha256(payload.read_bytes()).hexdigest()
            if payload_hash != report_actor.get("skeletalSha256"):
                raise RuntimeError(f"Skeletal export report hash mismatch at index {index}")

    manifest = json.loads(args.base_manifest.read_text(encoding="utf-8"))
    actors = [dict(row) for row in manifest.get("actors", [])]
    by_ref = {canonical(row["authored_ref"]): row for row in actors}
    promotion_rows = []
    for target, payload in zip(selected, payloads, strict=True):
        data = payload.read_bytes()
        audit = decode_bytes(data)
        if audit["surface_count"] <= 0 or audit["totals"]["vertices"] <= 0:
            raise RuntimeError(f"Skeletal payload has no usable surfaces: {payload}")
        if audit["hierarchy_failed_edges"] != 0 or audit["hierarchy_max_residual"] > 1e-4:
            raise RuntimeError(f"Skeletal hierarchy reconstruction failed: {payload}")
        if audit["format_version"] >= 2 and (
            audit["canonical_bone_count"] < 1 or audit["canonical_hierarchy_max_residual"] > 1e-4
        ):
            raise RuntimeError(f"Canonical skeleton reconstruction failed: {payload}")
        if any(surface["bone_count"] > 0 and surface["zero_weight_vertices"] > 0 for surface in audit["surfaces"]):
            raise RuntimeError(f"Rigged surface contains zero-weight vertices: {payload}")
        authored_ref = canonical(target["authoredRef"])
        actor = by_ref.get(authored_ref)
        if actor is None:
            actor = {
                "index": len(actors),
                "id": target["id"],
                "category": target["category"],
                "authored_ref": authored_ref,
                "base_form": canonical(target["base"]),
                "mesh": "",
            }
            actors.append(actor)
            by_ref[authored_ref] = actor
        actor["skeletal"] = "res://" + payload.relative_to(project_root).as_posix()
        actor["skeletal_sha256"] = hashlib.sha256(data).hexdigest()
        actor["skeletal_surfaces"] = audit["surface_count"]
        actor["skeletal_vertices"] = audit["totals"]["vertices"]
        actor["skeletal_format_version"] = audit["format_version"]
        actor["skeletal_canonical_bones"] = audit["canonical_bone_count"]
        promotion_rows.append(
            {
                "id": target["id"],
                "authored_ref": authored_ref,
                "base_form": canonical(target["base"]),
                "payload": str(payload),
                "sha256": actor["skeletal_sha256"],
                "surfaces": actor["skeletal_surfaces"],
                "vertices": actor["skeletal_vertices"],
                "format_version": actor["skeletal_format_version"],
                "canonical_bones": actor["skeletal_canonical_bones"],
            }
        )

    promotion_ledger = {
        canonical(row["authored_ref"]): dict(row) for row in manifest.get("skeletal_promotions", [])
    }
    for row in promotion_rows:
        promotion_ledger[canonical(row["authored_ref"])] = row
    manifest.update(
        schema="opennv-godot-actor-cache/v2",
        status="pass",
        actor_count=len(actors),
        skeletal_actor_count=sum(1 for actor in actors if actor.get("skeletal")),
        actors=actors,
        skeletal_promotions=sorted(promotion_ledger.values(), key=lambda row: int(row["authored_ref"], 16)),
    )
    if args.export_report:
        provenance = {
            "report": str(args.export_report.resolve()),
            "report_sha256": hashlib.sha256(args.export_report.read_bytes()).hexdigest(),
            "roster": str(args.roster.resolve()),
            "roster_sha256": hashlib.sha256(args.roster.read_bytes()).hexdigest(),
            "payload_root": str(args.payload_root.resolve()),
        }
        manifest["skeletal_export_provenance"] = provenance
        provenance_batches = {
            row["report_sha256"]: dict(row)
            for row in manifest.get("skeletal_export_provenance_batches", [])
        }
        provenance_batches[provenance["report_sha256"]] = provenance
        manifest["skeletal_export_provenance_batches"] = list(provenance_batches.values())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"OPENNV_SKELETAL_ACTORS_PROMOTED promoted={len(promotion_rows)} "
        f"actors={len(actors)} skeletal={manifest['skeletal_actor_count']} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
