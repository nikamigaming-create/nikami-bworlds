#!/usr/bin/env python3
"""Compile exact SCPT local definitions and GetScriptVariable structural coverage.

This deliberately does not manufacture live values.  A definition can be resolved
while its value remains unavailable until a save overlay or the script VM supplies it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path


def canonical(value: object) -> str | None:
    if value in (None, "", 0, "0"):
        return None
    if isinstance(value, str):
        return f"0x{int(value, 16):08x}"
    return f"0x{int(value):08x}"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def compile_index(semantic_dir: Path, output: Path) -> dict:
    manifest_path = semantic_dir / "manifest.json"
    scripts_path = semantic_dir / "scripts.json"
    bases_path = semantic_dir / "placement-bases.json"
    owners_path = semantic_dir / "script-owners.json"
    packages_path = semantic_dir / "actor-packages.json"
    blueprints_path = semantic_dir / "actor-blueprints.json"
    actor_bases_path = semantic_dir / "actor-bases.json"
    actor_lists_path = semantic_dir / "actor-lists.json"
    actor_placements_path = semantic_dir / "actor-placements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    scripts_doc = json.loads(scripts_path.read_text(encoding="utf-8"))
    bases_doc = json.loads(bases_path.read_text(encoding="utf-8"))
    owners_doc = json.loads(owners_path.read_text(encoding="utf-8"))
    packages_doc = json.loads(packages_path.read_text(encoding="utf-8"))
    blueprints_doc = json.loads(blueprints_path.read_text(encoding="utf-8"))
    require(manifest.get("schema") == "opennv-semantic-database/v1", "unexpected semantic manifest schema")
    require(scripts_doc.get("schema") == "opennv-semantic-scripts/v1", "unexpected scripts schema")
    require(bases_doc.get("schema") == "opennv-semantic-placement-bases/v1", "unexpected placement bases schema")
    require(owners_doc.get("schema") == "opennv-semantic-script-owners/v1", "unexpected script owners schema")
    require(packages_doc.get("schema") == "opennv-semantic-actor-packages/v1", "unexpected packages schema")
    require(blueprints_doc.get("schema") == "opennv-actor-blueprints/v1", "unexpected actor blueprints schema")
    require(blueprints_doc.get("semantic_manifest_sha256") == digest(manifest_path), "actor blueprints use a stale semantic manifest")
    require(blueprints_doc.get("actor_bases_sha256") == digest(actor_bases_path), "actor blueprints use stale actor bases")
    require(blueprints_doc.get("actor_lists_sha256") == digest(actor_lists_path), "actor blueprints use stale actor lists")
    require(blueprints_doc.get("actor_placements_sha256") == digest(actor_placements_path), "actor blueprints use stale actor placements")

    scripts = scripts_doc["scripts"]
    script_by_id = {canonical(row["id"]): row for row in scripts}
    require(len(script_by_id) == len(scripts), "duplicate script FormID")
    definitions = {}
    duplicate_local_indices = []
    conflicting_local_indices = []
    for script_id, script in script_by_id.items():
        locals_by_index = {}
        for local in script.get("scriptLocals", []):
            index = int(local.get("index", -1))
            if index in locals_by_index:
                duplicate = {
                    "script": script_id,
                    "index": index,
                    "firstName": locals_by_index[index]["name"],
                    "duplicateName": str(local.get("name", "")),
                }
                duplicate_local_indices.append(duplicate)
                if duplicate["firstName"].casefold() != duplicate["duplicateName"].casefold():
                    conflicting_local_indices.append(duplicate)
                continue
            locals_by_index[index] = {
                "index": index,
                "name": str(local.get("name", "")),
                "type": int(local.get("type", 0)),
            }
        definitions[script_id] = {
            "editorId": script.get("editorId", ""),
            "locals": [locals_by_index[key] for key in sorted(locals_by_index)],
        }

    base_rows = bases_doc["records"]
    require(len({canonical(row["id"]) for row in base_rows}) == len(base_rows), "duplicate placement-base FormID")
    base_script = {
        canonical(row["id"]): canonical(row.get("script"))
        for row in owners_doc["owners"] if row.get("script")
    }
    blueprints = blueprints_doc["blueprints"]
    blueprint_script = {
        canonical(row["id"]): canonical(row.get("script"))
        for row in blueprints if row.get("script")
    }
    base_script.update(blueprint_script)

    reference_base = {}
    placement_shards = sorted((semantic_dir / "placements").glob("*.json"))
    require(len(placement_shards) == 256, f"expected 256 placement shards, found {len(placement_shards)}")
    for shard in placement_shards:
        for placement in json.loads(shard.read_text(encoding="utf-8"))["placements"]:
            reference = canonical(placement.get("id"))
            base = canonical(placement.get("base"))
            if reference and base:
                require(reference not in reference_base, f"duplicate placement reference {reference}")
                reference_base[reference] = base
    require(
        len(reference_base) == int(manifest.get("counts", {}).get("placements", -1)),
        "placement shard denominator differs from semantic manifest",
    )

    package_consumers = defaultdict(list)
    for blueprint in blueprints:
        actor_base = canonical(blueprint["id"])
        for package_id in blueprint.get("packages", []):
            package_consumers[canonical(package_id)].append(actor_base)

    population_by_base = defaultdict(int)
    for placement in blueprints_doc.get("population", []):
        population_by_base[canonical(placement.get("base"))] += 1

    condition_rows = []
    explicit_rows = 0
    null_rows = 0
    definition_resolved = 0
    static_reachable_rows = 0
    blueprint_applications = 0
    population_applications = 0
    unresolved_reasons = defaultdict(int)
    explicit_targets = {}
    for package in packages_doc["packages"]:
        package_id = canonical(package["id"])
        for condition_index, condition in enumerate(package.get("conditionData", [])):
            if int(condition.get("functionId", -1)) != 53:
                continue
            target = canonical(condition.get("param1"))
            local_index = int(condition.get("param2Raw", -1))
            consumers = package_consumers.get(package_id, [])
            if not target:
                null_rows += 1
                condition_rows.append({
                    "package": package_id, "conditionIndex": condition_index,
                    "targetMode": "null", "localIndex": local_index,
                    "runOn": int(condition.get("runOn", 0)),
                    "runOnTarget": bool(condition.get("runOnTarget", False)),
                    "reference": canonical(condition.get("reference")),
                    "flags": int(condition.get("flags", 0)),
                    "staticReachable": bool(consumers),
                    "definitionResolved": False, "liveValueResolved": False,
                    "reason": "null_reference_semantics_unproven",
                })
                continue
            explicit_rows += 1
            target_base = reference_base.get(target)
            script_id = base_script.get(target_base)
            reason = None
            local = None
            if target_base is None:
                reason = "target_reference_missing"
            elif script_id is None:
                reason = "target_script_missing"
            elif script_id not in definitions:
                reason = "script_definition_missing"
            else:
                local = next((row for row in definitions[script_id]["locals"] if row["index"] == local_index), None)
                if local is None:
                    reason = "local_index_missing"
            resolved = reason is None
            if resolved:
                definition_resolved += 1
            else:
                unresolved_reasons[reason] += 1
            if consumers:
                static_reachable_rows += 1
                blueprint_applications += len(consumers)
                population_applications += sum(population_by_base[consumer] for consumer in consumers)
            row = {
                "package": package_id,
                "conditionIndex": condition_index,
                "targetMode": "reference",
                "targetReference": target,
                "param1IsForm": bool(condition.get("param1IsForm", False)),
                "runOn": int(condition.get("runOn", 0)),
                "runOnTarget": bool(condition.get("runOnTarget", False)),
                "reference": canonical(condition.get("reference")),
                "flags": int(condition.get("flags", 0)),
                "targetBase": target_base,
                "script": script_id,
                "localIndex": local_index,
                "localName": local["name"] if resolved else None,
                "staticReachable": bool(consumers),
                "consumerBases": consumers,
                "definitionResolved": resolved,
                "liveValueResolved": False,
            }
            if reason:
                row["reason"] = reason
            condition_rows.append(row)
            explicit_targets[target] = {"base": target_base, "script": script_id}

    function_conditions = sum(
        1 for package in packages_doc["packages"] for condition in package.get("conditionData", [])
        if int(condition.get("functionId", -1)) == 53
    )
    result = {
        "schema": "opennv-script-variable-index/v1",
        "status": "pass" if not conflicting_local_indices and definition_resolved == explicit_rows else "fail",
        "provenance": {
            "loadOrderSha256": manifest.get("load_order_sha256"),
            "semanticManifestSha256": digest(manifest_path),
            "scriptsSha256": digest(scripts_path),
            "placementBasesSha256": digest(bases_path),
            "scriptOwnersSha256": digest(owners_path),
            "actorPackagesSha256": digest(packages_path),
            "actorBlueprintsSha256": digest(blueprints_path),
        },
        "counts": {
            "scripts": len(definitions),
            "scriptLocals": sum(len(row["locals"]) for row in definitions.values()),
            "physicalScriptLocalRows": sum(len(row.get("scriptLocals", [])) for row in scripts),
            "actorBlueprintsWithScript": len(blueprint_script),
            "function53Conditions": function_conditions,
            "function53ExplicitReferenceRows": explicit_rows,
            "function53NullReferenceRows": null_rows,
            "definitionResolvedExplicitRows": definition_resolved,
            "definitionUnresolvedExplicitRows": explicit_rows - definition_resolved,
            "staticReachableExplicitRows": static_reachable_rows,
            "evaluatorEligibleExplicitRows": explicit_rows,
            "blueprintConditionApplications": blueprint_applications,
            "populationConditionApplications": population_applications,
            "liveValueResolvedExplicitRows": 0,
            "duplicateLocalIndices": len(duplicate_local_indices),
            "conflictingLocalIndices": len(conflicting_local_indices),
        },
        "definitions": definitions,
        "blueprintScripts": blueprint_script,
        "explicitTargets": explicit_targets,
        "function53": condition_rows,
        "unresolvedReasons": dict(sorted(unresolved_reasons.items())),
        "diagnostics": {
            "duplicateLocalIndices": duplicate_local_indices,
            "conflictingLocalIndices": conflicting_local_indices,
        },
        "policy": "Definitions are authoritative load-order winners; values remain unresolved until save/VM state supplies them.",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("OPENNV_SCRIPT_VARIABLE_INDEX " + json.dumps(result["counts"], sort_keys=True))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--semantic-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compile_index(args.semantic_dir.resolve(), args.output.resolve())
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
