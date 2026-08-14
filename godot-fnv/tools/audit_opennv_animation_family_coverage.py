#!/usr/bin/env python3
"""Group promoted actors by canonical rig and report honest animation coverage."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from decode_opennv_skeletal_actor import decode_bytes


def canonical(value: object) -> str:
    text = str(value or "").strip().lower()
    if not text:
        return ""
    return f"0x{int(text, 16):x}"


def resource_path(project_root: Path, value: object) -> Path:
    text = str(value or "")
    if not text.startswith("res://"):
        raise ValueError(f"non-resource payload path: {text}")
    return project_root / text.removeprefix("res://")


def rig_signature(summary: dict, payload_sha: str) -> str:
    bones = summary.get("canonical_bones", [])
    if not bones:
        return "legacy:" + payload_sha
    identity = "\n".join(
        f"{str(bone.get('name', '')).casefold()}|{int(bone.get('parent', -1))}"
        for bone in bones
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def decode_payload(task: tuple[int, str, str]) -> tuple[int, str, int, str]:
    index, path_text, expected_sha = task
    try:
        payload = Path(path_text).read_bytes()
        payload_sha = hashlib.sha256(payload).hexdigest()
        if payload_sha != expected_sha:
            raise ValueError("skeletal SHA mismatch")
        summary = decode_bytes(payload)
        return index, rig_signature(summary, payload_sha), int(summary.get("canonical_bone_count", 0)), ""
    except (OSError, ValueError) as error:
        return index, "", 0, str(error)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--actor-blueprints", type=Path, required=True)
    parser.add_argument("--actor-bases", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    blueprint_doc = json.loads(args.actor_blueprints.read_text(encoding="utf-8"))
    base_doc = json.loads(args.actor_bases.read_text(encoding="utf-8"))
    if blueprint_doc.get("schema") != "opennv-actor-blueprints/v1":
        raise ValueError("unexpected actor blueprint schema")
    if base_doc.get("schema") != "opennv-semantic-actor-bases/v1":
        raise ValueError("unexpected actor base schema")

    population = {canonical(row.get("reference")): row for row in blueprint_doc.get("population", [])}
    blueprints = {canonical(row.get("id")): row for row in blueprint_doc.get("blueprints", [])}
    bases = {canonical(row.get("id")): row for row in base_doc.get("actors", [])}
    groups: dict[str, list[dict]] = defaultdict(list)
    failures: list[dict] = []

    skeletal_actors = [actor for actor in manifest.get("actors", []) if actor.get("skeletal")]
    tasks = [
        (
            index,
            str(resource_path(args.project_root.resolve(), actor["skeletal"])),
            str(actor.get("skeletal_sha256", "")).lower(),
        )
        for index, actor in enumerate(skeletal_actors)
    ]
    worker_count = min(8, max(1, os.cpu_count() or 1))
    with ProcessPoolExecutor(max_workers=worker_count) as executor:
        decoded = executor.map(decode_payload, tasks, chunksize=16)
        decoded_by_index = {index: (signature, bones, error) for index, signature, bones, error in decoded}

    for index, actor in enumerate(skeletal_actors):
        skeletal = str(actor.get("skeletal", ""))
        signature, canonical_bones, error = decoded_by_index[index]
        if error:
            failures.append({"actor": actor.get("authored_ref"), "error": error})
            continue

        placement = population.get(canonical(actor.get("authored_ref")), {})
        blueprint = blueprints.get(canonical(placement.get("base")), {})
        model_category = blueprint.get("categories", {}).get("model", {})
        source_ids: list[str] = []
        if model_category.get("source"):
            source_ids.append(canonical(model_category["source"]))
        source_ids.extend(canonical(value) for value in model_category.get("candidate_sources", []))
        models = sorted({model for source_id in source_ids for model in bases.get(source_id, {}).get("models", [])})
        groups[signature].append({
            "actor": canonical(actor.get("authored_ref")),
            "category": str(actor.get("category", "")),
            "animation": str(actor.get("animation_idle", "")),
            "canonicalBones": canonical_bones,
            "models": models,
        })

    family_rows = []
    animated_skeletal = 0
    for signature, actors in groups.items():
        animations = Counter(row["animation"] for row in actors if row["animation"])
        model_counts = Counter(model for row in actors for model in row["models"])
        animated = sum(1 for row in actors if row["animation"])
        animated_skeletal += animated
        family_rows.append({
            "signature": signature,
            "actors": len(actors),
            "animatedActors": animated,
            "unanimatedActors": len(actors) - animated,
            "canonicalBones": max(row["canonicalBones"] for row in actors),
            "categories": dict(sorted(Counter(row["category"] for row in actors).items())),
            "actorReferences": sorted(row["actor"] for row in actors),
            "authoredModels": [{"path": key, "actors": value} for key, value in model_counts.most_common()],
            "animations": [{"path": key, "actors": value} for key, value in animations.most_common()],
        })
    family_rows.sort(key=lambda row: (-row["unanimatedActors"], -row["actors"], row["signature"]))

    actors = manifest.get("actors", [])
    skeletal_count = sum(bool(row.get("skeletal")) for row in actors)
    static_animated = sum(bool(row.get("animation_idle")) and not bool(row.get("skeletal")) for row in actors)
    report = {
        "schema": "opennv-animation-family-coverage/v1",
        "status": "pass" if not failures else "fail",
        "counts": {
            "actors": len(actors),
            "skeletalActors": skeletal_count,
            "animatedSkeletalActors": animated_skeletal,
            "unanimatedSkeletalActors": skeletal_count - animated_skeletal,
            "staticActorsWithAssignedAnimation": static_animated,
            "rigFamilies": len(family_rows),
            "fullyAnimatedRigFamilies": sum(row["unanimatedActors"] == 0 for row in family_rows),
            "failures": len(failures),
        },
        "families": family_rows,
        "failures": failures,
        "policy": "Animation coverage requires both a validated skeletal payload and an assigned authored clip; static snapshots never count.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_ANIMATION_FAMILY_COVERAGE " + json.dumps(report["counts"], sort_keys=True))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
