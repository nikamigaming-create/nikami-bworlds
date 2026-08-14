#!/usr/bin/env python3
"""Assign one validated retail creature idle to exact compatible rig families."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from decode_opennv_animation import decode_bytes as decode_animation
from decode_opennv_skeletal_actor import decode_bytes as decode_skeleton


def canonical(value: object) -> str:
    return f"0x{int(str(value), 16):x}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--family-audit", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--animation", required=True)
    parser.add_argument("--allow-dominant-model", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    audit = json.loads(args.family_audit.read_text(encoding="utf-8"))
    if audit.get("schema") != "opennv-animation-family-coverage/v1" or audit.get("status") != "pass":
        raise ValueError("animation-family audit is not promotable")
    animation_path = args.project_root.resolve() / args.animation.removeprefix("res://")
    animation_payload = animation_path.read_bytes()
    animation_sha = hashlib.sha256(animation_payload).hexdigest()
    animation = decode_animation(animation_payload)
    animation_tracks = {str(row.get("name", "")).casefold() for row in animation.get("tracks", [])}
    if not animation_tracks:
        raise ValueError("animation has no transform tracks")
    target_model = args.model.casefold().replace("/", "\\")
    target_refs: set[str] = set()
    family_signatures: list[str] = []
    actors_by_ref = {canonical(row.get("authored_ref")): row for row in manifest.get("actors", [])}
    for family in audit.get("families", []):
        model_counts = {
            str(row.get("path", "")).casefold().replace("/", "\\"): int(row.get("actors", 0))
            for row in family.get("authoredModels", [])
            if "nvvoid" not in str(row.get("path", "")).casefold()
        }
        exact_model = set(model_counts) == {target_model}
        dominant_model = (
            args.allow_dominant_model
            and target_model in model_counts
            and model_counts[target_model] > max(
                [count for model, count in model_counts.items() if model != target_model] or [0]
            )
        )
        if not exact_model and not dominant_model:
            continue
        family_refs = {canonical(value) for value in family.get("actorReferences", [])}
        representative = actors_by_ref.get(next(iter(family_refs), ""), {})
        skeleton_path = args.project_root.resolve() / str(representative.get("skeletal", "")).removeprefix("res://")
        skeleton = decode_skeleton(skeleton_path.read_bytes())
        skeleton_bones = {str(row.get("name", "")).casefold() for row in skeleton.get("canonical_bones", [])}
        missing_tracks = sorted(animation_tracks - skeleton_bones)
        if missing_tracks:
            raise ValueError(
                f"clip is incompatible with rig {family.get('signature')}: "
                f"{len(missing_tracks)} unresolved tracks"
            )
        target_refs.update(family_refs)
        family_signatures.append(str(family.get("signature", "")))
    if not target_refs:
        raise ValueError(f"no exact rig families resolved for {args.model}")

    promoted = 0
    for actor in manifest.get("actors", []):
        if canonical(actor.get("authored_ref")) not in target_refs:
            continue
        if not actor.get("skeletal"):
            raise ValueError(f"target actor lacks skeletal payload: {actor.get('authored_ref')}")
        actor["animation_idle"] = args.animation
        actor["animation_idle_sha256"] = animation_sha
        promoted += 1
    if promoted != len(target_refs):
        raise ValueError(f"promotion lost references: expected {len(target_refs)}, wrote {promoted}")
    promotions = [
        row for row in manifest.get("creature_idle_promotions", [])
        if str(row.get("model", "")).casefold().replace("/", "\\") != target_model
    ]
    promotions.append({
        "model": args.model,
        "animation": args.animation,
        "animation_sha256": animation_sha,
        "rig_signatures": sorted(family_signatures),
        "actors": promoted,
        "allow_dominant_model": bool(args.allow_dominant_model),
    })
    manifest["creature_idle_promotions"] = promotions
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"OPENNV_CREATURE_IDLE_PROMOTED model={args.model} actors={promoted} families={len(family_signatures)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
