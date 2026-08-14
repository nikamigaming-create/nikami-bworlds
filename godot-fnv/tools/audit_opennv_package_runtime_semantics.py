#!/usr/bin/env python3
"""Census authored PACK use against the Godot actor-runtime semantic tiers."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


KNOWN_TYPES = set(range(17))
ACTIVITY_STATE_TYPES = set(range(11)) | set(range(12, 17))
ACTION_ANIMATION_TYPES = {3, 4}
INTERACTION_TYPES: set[int] = set()


def canonical_form_id(value: object) -> str:
    text = str(value).strip().casefold()
    try:
        return f"0x{int(text, 16 if text.startswith('0x') else 10):x}"
    except ValueError:
        return text


def definition_reference_target_shape_configured(package: dict) -> bool:
    """Match definitions that can configure a reference-navigation branch.

    This is deliberately not a claim that a target is resident, reachable,
    moving or arrived. Those are runtime integration counters.
    """
    package_type = int((package.get("packageData") or {}).get("type", -1))
    location_type = int((package.get("packageLocation") or {}).get("type", -1))
    target_type = int((package.get("packageTarget") or {}).get("type", -1))
    target_value = (package.get("packageTarget") or {}).get("target")
    location_value = (package.get("packageLocation") or {}).get("location")
    target_ref = "" if target_value is None else str(target_value).strip()
    location_ref = "" if location_value is None else str(location_value).strip()
    if package_type in {0, 1, 2, 7, 15}:
        return target_type == 0 and bool(target_ref)
    if package_type in {3, 4, 9, 16}:
        return location_type == 0 and bool(location_ref)
    if package_type in {8, 14}:
        return ((location_type == 0 and bool(location_ref))
                or (target_type == 0 and bool(target_ref)))
    if package_type in {5, 12}:
        return location_type == 0 and bool(location_ref)
    if package_type == 13:
        return (location_type == 0 and bool(location_ref)) or location_type == 6
    if package_type == 6:
        return ((target_type == 0 and bool(target_ref))
                or (location_type == 0 and bool(location_ref))
                or location_type == 6)
    if package_type == 10:
        return target_type == 0 and bool(target_ref)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--blueprints", type=Path, required=True)
    parser.add_argument("--actor-manifest", type=Path, required=True)
    parser.add_argument("--action-clip", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    packages_doc = json.loads(args.packages.read_text(encoding="utf-8"))
    blueprint_doc = json.loads(args.blueprints.read_text(encoding="utf-8"))
    actor_manifest = json.loads(args.actor_manifest.read_text(encoding="utf-8"))
    if packages_doc.get("schema") != "opennv-semantic-actor-packages/v1":
        raise SystemExit("unexpected package schema")
    if blueprint_doc.get("schema") != "opennv-actor-blueprints/v1":
        raise SystemExit("unexpected actor-blueprint schema")

    packages = packages_doc.get("packages", [])
    package_by_id = {str(row.get("id", "")).lower(): row for row in packages}
    package_types = {
        package_id: int((row.get("packageData") or {}).get("type", -1))
        for package_id, row in package_by_id.items()
    }
    blueprint_by_id = {
        canonical_form_id(row.get("id", "")): row for row in blueprint_doc.get("blueprints", [])
    }
    physical = Counter(package_types.values())
    configured_reference_shape_by_type = Counter(
        int((row.get("packageData") or {}).get("type", -1))
        for row in packages if definition_reference_target_shape_configured(row)
    )
    blueprint_applications: Counter[int] = Counter()
    population_applications: Counter[int] = Counter()
    generic_action_clip_eligible_definitions: Counter[int] = Counter()
    generic_action_clip_eligible_population: Counter[int] = Counter()
    missing_package_ids: set[str] = set()
    for blueprint in blueprint_by_id.values():
        for package_id_value in blueprint.get("packages", []):
            package_id = str(package_id_value).lower()
            if package_id not in package_types:
                missing_package_ids.add(package_id)
                continue
            blueprint_applications[package_types[package_id]] += 1
    for placement in blueprint_doc.get("population", []):
        blueprint = blueprint_by_id.get(canonical_form_id(placement.get("base", "")))
        if blueprint is None:
            continue
        for package_id_value in blueprint.get("packages", []):
            package_id = str(package_id_value).lower()
            if package_id not in package_types:
                missing_package_ids.add(package_id)
                continue
            population_applications[package_types[package_id]] += 1

    action_clip_files_present = all(path.is_file() for path in args.action_clip)
    action_package_ids: set[str] = set()
    if action_clip_files_present:
        for actor in actor_manifest.get("actors", []):
            category = str(actor.get("category", "")).casefold()
            if ("humanoid" not in category and "settler" not in category) or not actor.get("skeletal"):
                continue
            blueprint = blueprint_by_id.get(canonical_form_id(actor.get("base_form", "")))
            if blueprint is None:
                continue
            for package_id_value in blueprint.get("packages", []):
                package_id = str(package_id_value).lower()
                package_type = package_types.get(package_id, -1)
                if package_type not in ACTION_ANIMATION_TYPES:
                    continue
                action_package_ids.add(package_id)
                package = package_by_id[package_id]
                location_type = int((package.get("packageLocation") or {}).get("type", -1))
                # In-Cell and Package-Location selection are not implemented;
                # do not count those records as eligible merely because a
                # generic humanoid clip exists.
                if location_type not in {0, 2, 3, 6}:
                    continue
                generic_action_clip_eligible_population[package_type] += 1
        for package_id in action_package_ids:
            package = package_by_id[package_id]
            location_type = int((package.get("packageLocation") or {}).get("type", -1))
            if location_type in {0, 2, 3, 6}:
                generic_action_clip_eligible_definitions[package_types[package_id]] += 1

    rows = []
    for package_type in sorted(physical):
        rows.append({
            "packageType": package_type,
            "packages": physical[package_type],
            "blueprintApplications": blueprint_applications[package_type],
            "populationApplications": population_applications[package_type],
            "activityState": package_type in ACTIVITY_STATE_TYPES,
            "definitionReferenceTargetShapeConfiguredPackages": configured_reference_shape_by_type[package_type],
            "genericActionClipEligibleDefinitions": generic_action_clip_eligible_definitions[package_type],
            "genericActionClipEligiblePopulationApplications": generic_action_clip_eligible_population[package_type],
            "worldInteraction": package_type in INTERACTION_TYPES,
            "knownType": package_type in KNOWN_TYPES,
        })
    known_packages = sum(count for package_type, count in physical.items() if package_type in KNOWN_TYPES)
    result = {
        "schema": "opennv-package-runtime-semantics-audit/v1",
        "status": "partial",
        "counts": {
            "packages": len(packages),
            "knownTypePackages": known_packages,
            "unknownTypePackages": len(packages) - known_packages,
            "blueprintApplications": sum(blueprint_applications.values()),
            "populationApplications": sum(population_applications.values()),
            "missingPackageIds": len(missing_package_ids),
            "activityStateMetadataPackages": sum(physical[t] for t in ACTIVITY_STATE_TYPES),
            "definitionReferenceTargetShapeConfiguredPackages": sum(configured_reference_shape_by_type.values()),
            "genericActionClipEligiblePackages": sum(generic_action_clip_eligible_definitions.values()),
            "genericActionClipEligiblePopulationApplications": sum(generic_action_clip_eligible_population.values()),
            "authoredActionClipFilesPresent": len(args.action_clip) if action_clip_files_present else 0,
            "worldInteractionPackages": 0,
        },
        "types": rows,
        "missingPackageIds": sorted(missing_package_ids),
        "limitations": [
            "Generic Eat/Sleep clips dispatch only on eligible skeletal humanoid/settler actor records; they are not per-PACK authored clips and furniture selection/completion remain unsupported.",
            "Configured reference-target shape does not prove live selection, target residency, NAVM reachability, movement or arrival.",
            "Furniture, doors, dialogue and combat interactions are not yet executed by PACK state.",
            "Reference and linked-reference navigation is implemented only while the target cell is resident.",
            "Five malformed negative package types remain fail-closed.",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("OPENNV_PACKAGE_RUNTIME_SEMANTICS " + json.dumps(result["counts"], sort_keys=True))
    return 0 if not missing_package_ids else 1


if __name__ == "__main__":
    raise SystemExit(main())
