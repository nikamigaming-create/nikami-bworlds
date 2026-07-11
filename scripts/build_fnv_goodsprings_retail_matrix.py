#!/usr/bin/env python3
"""Build the exact retail/OpenMW comparison roster for Goodsprings.

The output contains metadata, FormIDs, appearance-record links, and FaceGen
fingerprints only.  It never copies Bethesda meshes, textures, or coefficient
payloads into the repository.
"""

import argparse
import hashlib
import json
from pathlib import Path

from export_esm4_catalog import ESM4Catalog


TARGETS = (
    ("easy-pete", 0x104C80, "named-humanoid"),
    ("sunny-smiles", 0x104E85, "named-humanoid"),
    ("trudy", 0x104C6D, "named-humanoid"),
    ("chet", 0x104C79, "named-humanoid"),
    ("ringo", 0x104C7D, "named-humanoid"),
    ("doc-mitchell", 0x104C0F, "named-humanoid"),
    ("joe-cobb", 0x104C68, "named-humanoid"),
    ("goodsprings-settler-01", 0x104F03, "settler-humanoid"),
    ("goodsprings-settler-02", 0x104F06, "settler-humanoid"),
    ("goodsprings-settler-03", 0x104F0A, "settler-humanoid"),
    ("goodsprings-settler-04", 0x104F08, "settler-humanoid"),
    ("goodsprings-powder-ganger-01", 0x104C70, "quest-combatant-humanoid"),
    ("goodsprings-powder-ganger-02", 0x104C77, "quest-combatant-humanoid"),
    ("goodsprings-powder-ganger-03", 0x104C75, "quest-combatant-humanoid"),
    ("goodsprings-powder-ganger-04", 0x104DF2, "quest-combatant-humanoid"),
    ("goodsprings-powder-ganger-05", 0x104C72, "quest-combatant-humanoid"),
    ("goodsprings-powder-ganger-06", 0x104C73, "quest-combatant-humanoid"),
    ("victor", 0x1073E8, "named-robot"),
    ("cheyenne", 0x10588E, "named-creature"),
)

TRAITS_TEMPLATE_FLAG = 0x0001
USE_TEMPLATE_ACTOR_FLAG = 0x00000100


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def form_int(value):
    return int(value, 16) if value else None


def record_link(catalog, value):
    if value is None:
        return None
    record = catalog.records.get(value, {})
    result = {
        "form": f"0x{value:x}",
        "openmwForm": f"FormId:0x{value:x}",
        "type": record.get("type", "missing"),
        "editorId": record.get("editorId", ""),
        "name": record.get("fullName", ""),
    }
    if record.get("models"):
        result["models"] = record["models"]
    return result


def appearance_record(catalog, record):
    head_parts = [form_int(value) for value in record.get("headParts", [])]
    return {
        "record": record_link(catalog, form_int(record.get("id"))),
        "race": record_link(catalog, form_int(record.get("race"))),
        "hair": record_link(catalog, form_int(record.get("hair"))),
        "eyes": record_link(catalog, form_int(record.get("eyes"))),
        "headParts": [record_link(catalog, value) for value in head_parts],
        "hairLength": record.get("hairLength"),
        "hairColorRgba": record.get("hairColorRgba"),
        "faceGenFingerprints": record.get("faceGenFingerprints", {}),
        "baseTemplate": record_link(catalog, form_int(record.get("baseTemplate"))),
        "templateFlags": record.get("templateFlags", 0),
        "actorFlags": record.get("actorFlags", 0),
    }


def template_chain(catalog, base_record):
    result = []
    seen = set()
    current = base_record
    for _ in range(8):
        template = form_int(current.get("baseTemplate"))
        if template is None or template in seen:
            break
        seen.add(template)
        template_record = catalog.records.get(template)
        result.append(record_link(catalog, template))
        if template_record is None:
            break
        current = template_record
    return result


def effective_traits_record(catalog, base_record):
    current = base_record
    seen = set()
    for _ in range(8):
        template = form_int(current.get("baseTemplate"))
        flags = current.get("templateFlags", 0)
        actor_flags = current.get("actorFlags", 0)
        if (
            template is None
            or not (actor_flags & USE_TEMPLATE_ACTOR_FLAG)
            or not (flags & TRAITS_TEMPLATE_FLAG)
            or template in seen
        ):
            return current
        seen.add(template)
        current = catalog.records.get(template, current)
    return current


def build_matrix(esm_path):
    catalog = ESM4Catalog(esm_path)
    catalog.parse()
    placement_by_id = {form_int(item["id"]): item for item in catalog.placements}
    targets = []

    for slug, ref_form, category in TARGETS:
        placement = placement_by_id.get(ref_form)
        if placement is None:
            raise RuntimeError(f"Missing declared Goodsprings reference 0x{ref_form:08x} ({slug})")
        base_form = form_int(placement.get("base"))
        base_record = catalog.records.get(base_form)
        if base_record is None:
            raise RuntimeError(f"Missing base record for 0x{ref_form:08x} ({slug})")
        cell_form = form_int(placement.get("parentCell"))
        cell = catalog.cells.get(cell_form, {})
        target = {
            "id": slug,
            "category": category,
            "reference": record_link(catalog, ref_form),
            "referenceEditorId": placement.get("editorId", ""),
            "base": record_link(catalog, base_form),
            "cell": {
                "form": placement.get("parentCell"),
                "openmwForm": placement.get("openmwParentCell"),
                "editorId": cell.get("editorId", ""),
                "name": cell.get("fullName", ""),
                "isExterior": cell.get("isExterior"),
            },
            "authoredPlacement": {
                "position": placement.get("pos"),
                "rotationRadians": placement.get("rot"),
            },
            "captureContract": {
                "retail": ["frontPortrait", "leftProfile", "rightProfile", "fullBodyIdle"],
                "openmw": ["frontPortrait", "leftProfile", "rightProfile", "fullBodyIdle"],
                "sameRecordAndStateRequired": True,
                "sameLightingRequired": True,
                "telemetryRequired": True,
                "humanVisualVerdictRequired": True,
            },
        }
        if base_record.get("type") == "NPC_":
            traits_record = effective_traits_record(catalog, base_record)
            target["appearance"] = {
                "authored": appearance_record(catalog, base_record),
                "templateChain": template_chain(catalog, base_record),
                "effectiveTraits": appearance_record(catalog, traits_record),
                "runtimeTraitsStatus": "must-match-xnvse-capture",
            }
        else:
            target["appearance"] = {
                "modelRecords": base_record.get("models", []),
                "runtimeTraitsStatus": "scene-graph-and-material-capture-required",
            }
        targets.append(target)

    humanoids = [item for item in targets if item["category"].endswith("humanoid")]
    return {
        "schema": "nikami-fnv-goodsprings-retail-matrix/v1",
        "source": {
            "file": esm_path.name,
            "sha256": sha256_file(esm_path),
            "recordCount": len(catalog.records),
            "placementCount": len(catalog.placements),
        },
        "scope": {
            "description": "Core Goodsprings named cast, all four settler variants, all six Ghost Town Gunfight Powder Gangers, Victor, and Cheyenne.",
            "humanoidCount": len(humanoids),
            "totalTargetCount": len(targets),
            "excludedForLaterCreatureMatrix": [
                "Goodsprings young bighorners",
                "nearby ravens",
                "tutorial geckos",
                "nearby mantises/scorpion/bloatflies",
            ],
        },
        "statusVocabulary": ["pending", "captured", "failing", "passed"],
        "targets": targets,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esm", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if not args.esm.is_file():
        raise SystemExit(f"Missing FalloutNV.esm: {args.esm}")
    result = build_matrix(args.esm)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out} ({len(result['targets'])} targets)")


if __name__ == "__main__":
    main()
