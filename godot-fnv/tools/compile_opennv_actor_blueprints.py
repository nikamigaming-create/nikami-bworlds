#!/usr/bin/env python3
"""Resolve FNV actor template categories and population references."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


CATEGORIES = {
    "traits": 0x0001,
    "stats": 0x0002,
    "factions": 0x0004,
    "actor_effects": 0x0008,
    "ai_data": 0x0010,
    "ai_packages": 0x0020,
    "model": 0x0040,
    "base_data": 0x0080,
    "inventory": 0x0100,
    "script": 0x0200,
}


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_blueprints(semantic_dir: Path, output_path: Path) -> dict:
    semantic_manifest_path = semantic_dir / "manifest.json"
    bases_path = semantic_dir / "actor-bases.json"
    lists_path = semantic_dir / "actor-lists.json"
    placements_path = semantic_dir / "actor-placements.json"
    bases = json.loads(bases_path.read_text(encoding="utf-8"))["actors"]
    lists = json.loads(lists_path.read_text(encoding="utf-8"))["lists"]
    placements = json.loads(placements_path.read_text(encoding="utf-8"))["placements"]
    by_id = {row["id"]: row for row in bases}
    lists_by_id = {row["id"]: row for row in lists}
    list_cycles: list[list[str]] = []
    missing_list_targets: set[str] = set()

    def list_leaves(list_id: str, stack: tuple[str, ...] = ()) -> list[str]:
        if list_id in stack:
            list_cycles.append(list(stack + (list_id,)))
            return []
        row = lists_by_id.get(list_id)
        if row is None:
            missing_list_targets.add(list_id)
            return []
        leaves = []
        for entry in row.get("leveledActorEntries", []):
            target = entry.get("item")
            if target in by_id:
                leaves.append(target)
            elif target in lists_by_id:
                leaves.extend(list_leaves(target, stack + (list_id,)))
            elif target:
                missing_list_targets.add(target)
        return sorted(set(leaves), key=lambda value: int(value, 16))

    blueprint_rows = []
    missing_templates: set[str] = set()
    template_cycles: list[list[str]] = []
    dynamic_categories = 0
    for actor_id in sorted(by_id, key=lambda value: int(value, 16)):
        actor = by_id[actor_id]
        categories = {}
        for category, flag in CATEGORIES.items():
            current = actor
            chain = []
            while True:
                current_id = current["id"]
                if current_id in chain:
                    template_cycles.append(chain + [current_id])
                    categories[category] = {"error": "cycle", "chain": chain + [current_id]}
                    break
                chain.append(current_id)
                target = current.get("baseTemplate")
                delegates = bool(int(current.get("templateFlags", 0)) & flag)
                if not delegates or not target:
                    categories[category] = {"source": current_id, "chain": chain}
                    break
                if target in by_id:
                    current = by_id[target]
                    continue
                if target in lists_by_id:
                    candidates = list_leaves(target)
                    categories[category] = {
                        "levelled_list": target,
                        "candidate_sources": candidates,
                        "chain": chain,
                    }
                    dynamic_categories += 1
                    break
                missing_templates.add(target)
                categories[category] = {"error": "missing", "target": target, "chain": chain}
                break
        package_sources = categories["ai_packages"]
        package_ids = []
        if package_sources.get("source") in by_id:
            package_ids = by_id[package_sources["source"]].get("packages", [])
        script_sources = categories["script"]
        script_id = None
        if script_sources.get("source") in by_id:
            script_id = by_id[script_sources["source"]].get("script")
        appearance_payload = {
            "traits": categories["traits"],
            "model": categories["model"],
            "inventory": categories["inventory"],
            "actor_type": actor["type"],
        }
        blueprint_rows.append({
            "id": actor_id,
            "type": actor["type"],
            "editor_id": actor.get("editorId", ""),
            "name": actor.get("fullName", ""),
            "categories": categories,
            "packages": package_ids,
            "script": script_id,
            "appearance_signature": hashlib.sha256(
                json.dumps(appearance_payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        })

    population = []
    missing_placement_bases = []
    for placement in placements:
        base = placement.get("base")
        if base not in by_id:
            missing_placement_bases.append(placement["id"])
            continue
        population.append({
            "reference": placement["id"],
            "base": base,
            "cell": placement.get("parentCell"),
            "position": placement.get("pos"),
            "rotation_radians": placement.get("rot"),
            "scale": placement.get("scale", 1.0),
            "record_flags": placement.get("recordFlags", 0),
            "enable_parent": placement.get("enableParent"),
            "enable_parent_flags": placement.get("enableParentFlags", 0),
            "source_plugin": placement.get("sourcePlugin"),
        })
    failures = bool(
        list_cycles or missing_list_targets or template_cycles
        or missing_templates or missing_placement_bases
    )
    result = {
        "schema": "opennv-actor-blueprints/v1",
        "status": "fail" if failures else "pass",
        "semantic_manifest_sha256": _sha(semantic_manifest_path),
        "actor_bases_sha256": _sha(bases_path),
        "actor_lists_sha256": _sha(lists_path),
        "actor_placements_sha256": _sha(placements_path),
        "counts": {
            "blueprints": len(blueprint_rows),
            "population_references": len(population),
            "levelled_lists": len(lists),
            "dynamic_template_categories": dynamic_categories,
            "missing_template_targets": len(missing_templates),
            "missing_list_targets": len(missing_list_targets),
            "template_cycles": len(template_cycles),
            "list_cycles": len(list_cycles),
            "missing_placement_bases": len(missing_placement_bases),
        },
        "blueprints": blueprint_rows,
        "population": population,
        "diagnostics": {
            "missing_template_targets": sorted(missing_templates),
            "missing_list_targets": sorted(missing_list_targets),
            "template_cycles": template_cycles,
            "list_cycles": list_cycles,
            "missing_placement_bases": missing_placement_bases,
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(result, separators=(",", ":")).encode("utf-8")
    output_path.write_bytes(encoded)
    manifest_path = output_path.with_suffix(".manifest.json")
    manifest_path.write_text(json.dumps({
        "schema": "opennv-actor-blueprint-manifest/v1",
        "status": result["status"],
        "blueprints_sha256": hashlib.sha256(encoded).hexdigest(),
        "semantic_manifest_sha256": result["semantic_manifest_sha256"],
        "counts": result["counts"],
    }, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--semantic-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()
    result = compile_blueprints(args.semantic_dir.resolve(), args.output.resolve())
    print("OPENNV_ACTOR_BLUEPRINTS " + json.dumps(result["counts"], sort_keys=True))
    return 0 if result["status"] == "pass" or args.allow_incomplete else 1


if __name__ == "__main__":
    raise SystemExit(main())
