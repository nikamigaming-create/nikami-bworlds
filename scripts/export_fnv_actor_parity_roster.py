#!/usr/bin/env python3
"""Export every FNV NPC/creature base and its authored references deterministically."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


DELETED_RECORD_FLAG = 0x20


def load_catalog_module(script_dir: Path):
    source = script_dir / "export_esm4_catalog.py"
    spec = importlib.util.spec_from_file_location("nikami_export_esm4_catalog", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load catalog parser: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_form(value: str | None) -> int:
    if not value:
        return 0
    return int(value, 16)


def stable_fingerprint(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def reference_sort_key(reference: dict[str, Any]) -> tuple[Any, ...]:
    flags = int(reference.get("recordFlags", 0))
    deleted = (flags & DELETED_RECORD_FLAG) != 0
    enable_parent = parse_form(reference.get("enableParent"))
    editor_id = str(reference.get("editorId", ""))
    return (
        deleted,
        enable_parent != 0,
        editor_id == "",
        parse_form(reference.get("id")),
    )


def compact_reference(reference: dict[str, Any]) -> dict[str, Any]:
    flags = int(reference.get("recordFlags", 0))
    return {
        "formId": reference.get("id"),
        "openMwId": reference.get("openmwId"),
        "recordType": reference.get("type"),
        "recordFlags": flags,
        "deleted": (flags & DELETED_RECORD_FLAG) != 0,
        "editorId": reference.get("editorId", ""),
        "parentCell": reference.get("parentCell"),
        "openMwParentCell": reference.get("openmwParentCell"),
        "enableParentFormId": reference.get("enableParent"),
        "openMwEnableParentId": reference.get("openmwEnableParent"),
        "enableParentFlags": int(reference.get("enableParentFlags", 0)),
        "position": reference.get("pos"),
        "rotation": reference.get("rot"),
        "scale": reference.get("scale", 1.0),
    }


def compact_base(base: dict[str, Any], references: list[dict[str, Any]], index: int) -> dict[str, Any]:
    ordered_references = sorted(references, key=reference_sort_key)
    usable_references = [
        reference for reference in ordered_references
        if (int(reference.get("recordFlags", 0)) & DELETED_RECORD_FLAG) == 0
    ]
    preferred = compact_reference(usable_references[0]) if usable_references else None
    base_projection = {
        key: base[key]
        for key in (
            "id", "openmwId", "type", "recordFlags", "editorId", "fullName", "actorFlags",
            "femaleFlag", "race", "openmwRace", "hair", "openmwHair", "eyes", "openmwEyes",
            "headParts", "openmwHeadParts", "baseTemplate", "openmwBaseTemplate", "templateFlags",
            "hairLength", "hairColorRgba", "faceGenFingerprints", "models", "modelSlots", "inventory",
            "defaultOutfit", "openmwDefaultOutfit", "sleepOutfit", "openmwSleepOutfit",
        )
        if key in base
    }
    return {
        "index": index,
        "baseFormId": base.get("id"),
        "openMwBaseId": base.get("openmwId"),
        "recordType": base.get("type"),
        "actorKind": "npc" if base.get("type") == "NPC_" else "creature",
        "recordFlags": int(base.get("recordFlags", 0)),
        "editorId": base.get("editorId", ""),
        "displayName": base.get("fullName", ""),
        "baseTemplateFormId": base.get("baseTemplate"),
        "openMwBaseTemplateId": base.get("openmwBaseTemplate"),
        "templateFlags": int(base.get("templateFlags", 0)),
        "raceFormId": base.get("race"),
        "openMwRaceId": base.get("openmwRace"),
        "female": bool(base.get("femaleFlag", False)),
        "models": list(base.get("models", [])),
        "modelSlots": list(base.get("modelSlots", [])),
        "defaultOutfitFormId": base.get("defaultOutfit"),
        "openMwDefaultOutfitId": base.get("openmwDefaultOutfit"),
        "sleepOutfitFormId": base.get("sleepOutfit"),
        "openMwSleepOutfitId": base.get("openmwSleepOutfit"),
        "inventory": list(base.get("inventory", [])),
        "head": {
            "hairFormId": base.get("hair"),
            "openMwHairId": base.get("openmwHair"),
            "eyesFormId": base.get("eyes"),
            "openMwEyesId": base.get("openmwEyes"),
            "headParts": list(base.get("headParts", [])),
            "openMwHeadParts": list(base.get("openmwHeadParts", [])),
            "hairLength": base.get("hairLength"),
            "hairColorRgba": base.get("hairColorRgba"),
            "faceGenFingerprints": base.get("faceGenFingerprints", {}),
        },
        "authoredReferenceCount": len(ordered_references),
        "usableAuthoredReferenceCount": len(usable_references),
        "spawnRequired": preferred is None,
        "preferredAuthoredReference": preferred,
        "authoredReferences": [compact_reference(reference) for reference in ordered_references],
        "baseFingerprintSha256": stable_fingerprint(base_projection),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esm", required=True, help="Path to FalloutNV.esm")
    parser.add_argument("--out", required=True, help="Destination JSON roster")
    parser.add_argument("--mod-index", type=int, default=1)
    args = parser.parse_args()

    esm_path = Path(args.esm).resolve()
    output_path = Path(args.out).resolve()
    if not esm_path.is_file():
        raise FileNotFoundError(esm_path)
    if args.mod_index < 0 or args.mod_index > 0xFF:
        raise ValueError("--mod-index must be between 0 and 255")

    module = load_catalog_module(Path(__file__).resolve().parent)
    catalog = module.ESM4Catalog(esm_path, mod_index=args.mod_index)
    catalog.parse()

    bases = {
        form_id: record
        for form_id, record in catalog.records.items()
        if record.get("type") in ("NPC_", "CREA")
    }
    references_by_base: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for record in catalog.records.values():
        if record.get("type") not in ("ACHR", "ACRE"):
            continue
        base_form = parse_form(record.get("base"))
        if base_form in bases:
            references_by_base[base_form].append(record)

    actors = [
        compact_base(bases[form_id], references_by_base.get(form_id, []), index)
        for index, form_id in enumerate(sorted(bases))
    ]
    source_hash = hashlib.sha256(esm_path.read_bytes()).hexdigest()
    document = {
        "schema": "nikami-fnv-all-actor-roster/v1",
        "source": str(esm_path),
        "sourceSha256": source_hash,
        "modIndex": args.mod_index,
        "counts": {
            "actorBases": len(actors),
            "npcBases": sum(actor["recordType"] == "NPC_" for actor in actors),
            "creatureBases": sum(actor["recordType"] == "CREA" for actor in actors),
            "authoredReferences": sum(actor["authoredReferenceCount"] for actor in actors),
            "basesWithUsableAuthoredReference": sum(not actor["spawnRequired"] for actor in actors),
            "spawnRequiredBases": sum(actor["spawnRequired"] for actor in actors),
        },
        "actors": actors,
    }
    document["rosterSha256"] = stable_fingerprint(document["actors"])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({
        "output": str(output_path),
        "counts": document["counts"],
        "rosterSha256": document["rosterSha256"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
