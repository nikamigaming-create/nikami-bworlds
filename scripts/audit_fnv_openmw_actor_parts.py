#!/usr/bin/env python3
"""Audit OpenMW FNV actor part assembly against authored Goodsprings records.

This is intentionally a hard accounting gate rather than a visual heuristic:
it compares the expected NPC appearance records from the Goodsprings matrix
with the OpenMW actor/face/material telemetry emitted during a proof run.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


LEDGER_RE = re.compile(r"World viewer actor ledger: (?P<body>.*)$")
FACE_AUDIT_RE = re.compile(r"FNV/ESM4 FACE DRAWABLE AUDIT (?P<actor>\S+) (?P<body>.*)$")
FACE_CHECK_RE = re.compile(r"FNV/ESM4 FACE CHECK (?P<editor>\S+): (?P<body>.*)$")
HAIR_VARIANT_RE = re.compile(
    r"FNV/ESM4 actor completeness: selected (?P<variant>Hat|NoHat) "
    r"(?P<kind>fallback hair variant|hair variant) actor=(?P<editor>\S+) "
    r"model=(?P<model>\S+) selected=(?P<selected>\d+) hidden=(?P<hidden>\d+)"
)


def parse_fields(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for match in re.finditer(r"(\w+)=((?:\"[^\"]*\")|(?:\([^\)]*\))|(?:\[[^\]]*\])|(?:\S+))", text):
        key = match.group(1)
        value = match.group(2)
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        fields[key] = value
    return fields


def form_int(value: Any) -> int:
    if value in (None, "", "0", "FormId:@0x0"):
        return 0
    text = str(value)
    text = text.replace("FormId:", "")
    text = text.replace("@", "")
    try:
        return int(text, 16) if text.lower().startswith("0x") else int(text)
    except ValueError:
        return 0


def form_key(value: int) -> int:
    return value & 0x00FFFFFF if value else 0


def normalized_model(value: str | None) -> str:
    text = (value or "").replace("\\", "/").lower()
    if text.startswith("meshes/"):
        text = text[len("meshes/") :]
    return text


def classify_model(model: str) -> str:
    path = normalized_model(model)
    leaf = path.rsplit("/", 1)[-1]
    if "beard" in leaf:
        return "beard"
    if "eyebrow" in leaf or "brow" in leaf:
        return "brow"
    if "eyeleft" in leaf:
        return "leftEye"
    if "eyeright" in leaf:
        return "rightEye"
    if "eyes" in leaf or leaf.startswith("eye"):
        return "eyes"
    if "mouth" in leaf:
        return "mouth"
    if "teethlower" in leaf:
        return "lowerTeeth"
    if "teethupper" in leaf:
        return "upperTeeth"
    if "tongue" in leaf:
        return "tongue"
    if "hair" in path:
        return "hair"
    if "head" in path:
        return "head"
    if "hand" in path:
        return "hand"
    if "cowboyhat" in path or "hat" in leaf:
        return "hat"
    if "weapon" in path or "rifle" in leaf or "pistol" in leaf:
        return "weapon"
    return "other"


def parse_vec3(value: str | None) -> tuple[float, float, float] | None:
    if not value or not value.startswith("(") or not value.endswith(")"):
        return None
    parts = value[1:-1].split(",")
    if len(parts) < 3:
        return None
    try:
        return (float(parts[0]), float(parts[1]), float(parts[2]))
    except ValueError:
        return None


@dataclass
class ActorPart:
    model: str
    role: str
    attached: bool = False
    vfs_exists: bool | None = None
    visual_drawables: int | None = None
    visual_geometry: int | None = None
    visual_mask: str | None = None


@dataclass
class FaceDrawable:
    model: str
    drawable: str
    role: str
    node_mask: str | None = None
    culling_active: str | None = None
    material_diffuse: tuple[float, float, float] | None = None
    material_emission: tuple[float, float, float] | None = None
    texture_stages: str = ""
    samplers: str = ""


@dataclass
class ActorAudit:
    ref_form: int
    base_form: int
    editor_id: str = ""
    name: str = ""
    parts: list[ActorPart] = field(default_factory=list)
    face_drawables: list[FaceDrawable] = field(default_factory=list)
    face_check: dict[str, str] = field(default_factory=dict)
    hair_variants: list[dict[str, Any]] = field(default_factory=list)


def load_openmw_actor_telemetry(log_path: Path) -> dict[int, ActorAudit]:
    actors: dict[int, ActorAudit] = {}
    editor_to_ref: dict[str, int] = {}
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if match := LEDGER_RE.search(line):
            fields = parse_fields(match.group("body"))
            phase = fields.get("phase", "")
            ref_form = form_int(fields.get("ref"))
            base_form = form_int(fields.get("base"))
            npc_editor = fields.get("npc") or fields.get("editor")
            if npc_editor and ref_form:
                editor_to_ref[npc_editor] = form_key(ref_form)
            if not phase.startswith("part-"):
                continue
            if ref_form == 0 and base_form == 0:
                continue
            key = form_key(ref_form or base_form)
            audit = actors.setdefault(key, ActorAudit(ref_form or base_form, base_form))
            audit.base_form = base_form or audit.base_form
            audit.name = fields.get("name", audit.name)
            model = fields.get("corrected") or fields.get("model") or ""
            role = classify_model(model)
            if phase in {"part-request", "part-attached"}:
                part = ActorPart(
                    model=normalized_model(model),
                    role=role,
                    attached=fields.get("attached") == "1" or phase == "part-attached",
                    vfs_exists=(fields.get("vfsExists") == "1") if "vfsExists" in fields else None,
                    visual_drawables=int(fields["visualDrawables"]) if fields.get("visualDrawables", "").isdigit() else None,
                    visual_geometry=int(fields["visualGeometry"]) if fields.get("visualGeometry", "").isdigit() else None,
                    visual_mask=fields.get("visualRootMask"),
                )
                audit.parts.append(part)
        elif match := FACE_AUDIT_RE.search(line):
            fields = parse_fields(match.group("body"))
            actor = match.group("actor")
            ref_form = form_int(actor) if actor.startswith("FormId:") else 0
            if ref_form == 0:
                continue
            audit = actors.setdefault(form_key(ref_form), ActorAudit(ref_form, 0))
            model = fields.get("model", "")
            material = fields.get("material", "")
            diffuse = None
            emission = None
            if material:
                if dm := re.search(r"diffuse=\(([^\)]*)\)", material):
                    diffuse = parse_vec3("(" + dm.group(1) + ")")
                if em := re.search(r"emission=\(([^\)]*)\)", material):
                    emission = parse_vec3("(" + em.group(1) + ")")
            inherited = fields.get("inheritedStatePath", "")
            audit.face_drawables.append(
                FaceDrawable(
                    model=normalized_model(model),
                    drawable=fields.get("drawable", ""),
                    role=classify_model(model),
                    node_mask=fields.get("nodeMask"),
                    culling_active=fields.get("cullingActive"),
                    material_diffuse=diffuse,
                    material_emission=emission,
                    texture_stages=match.group("body"),
                    samplers=match.group("body"),
                )
            )
        elif match := FACE_CHECK_RE.search(line):
            editor = match.group("editor")
            fields = parse_fields(match.group("body"))
            ref = editor_to_ref.get(editor)
            if ref is not None and ref in actors:
                actors[ref].editor_id = editor
                actors[ref].face_check = fields
        elif match := HAIR_VARIANT_RE.search(line):
            editor = match.group("editor")
            ref = editor_to_ref.get(editor)
            if ref is not None and ref in actors:
                actors[ref].hair_variants.append(
                    {
                        "variant": match.group("variant"),
                        "kind": match.group("kind"),
                        "model": normalized_model(match.group("model")),
                        "selected": int(match.group("selected")),
                        "hidden": int(match.group("hidden")),
                    }
                )
    return actors


def load_json_auto(path: Path) -> Any:
    raw = path.read_bytes()
    if len(raw) > 1 and raw[1:2] == b"\x00":
        text = raw.decode("utf-16le")
    else:
        text = raw.decode("utf-8-sig")
    return json.loads(text)


def expected_roles_from_target(target: dict[str, Any]) -> dict[str, Any]:
    expected: dict[str, Any] = {
        "roles": {
            "head": 1,
            "mouth": 1,
            "lowerTeeth": 1,
            "upperTeeth": 1,
            "tongue": 1,
            "leftEye": 1,
            "rightEye": 1,
        },
        "hairColorRgba": None,
        "hairModel": "",
    }
    traits = ((target.get("appearance") or {}).get("effectiveTraits") or {})
    if traits.get("hair"):
        expected["roles"]["hair"] = 1
        models = traits["hair"].get("models") or []
        expected["hairModel"] = normalized_model(models[0] if models else "")
    if traits.get("eyes"):
        expected["roles"]["eyes"] = 1
    for part in traits.get("headParts") or []:
        model = normalized_model((part or {}).get("models", [""])[0] if (part or {}).get("models") else "")
        role = classify_model(model)
        if role != "other":
            expected["roles"][role] = max(1, expected["roles"].get(role, 0))
    expected["hairColorRgba"] = traits.get("hairColorRgba")
    return expected


def close_rgb(a: tuple[float, float, float] | None, b: tuple[float, float, float] | None, eps: float = 0.015) -> bool:
    if a is None or b is None:
        return False
    return all(abs(x - y) <= eps for x, y in zip(a, b))


def audit_target(target: dict[str, Any], actors: dict[int, ActorAudit]) -> dict[str, Any]:
    ref = form_int((target.get("reference") or {}).get("openmwForm") or (target.get("reference") or {}).get("form"))
    ref_key = form_key(ref)
    base_key = form_key(form_int((target.get("base") or {}).get("openmwForm")))
    audit = actors.get(ref_key) or actors.get(base_key)
    base_audit = actors.get(base_key)
    expected = expected_roles_from_target(target)
    row: dict[str, Any] = {
        "id": target.get("id"),
        "reference": (target.get("reference") or {}).get("openmwForm") or (target.get("reference") or {}).get("form"),
        "expected": expected,
        "status": "pending",
        "failures": [],
        "observed": {},
    }
    if audit is None:
        row["status"] = "failing"
        row["failures"].append({"field": "actorTelemetry", "expected": "present", "actual": "missing"})
        return row

    attached_by_role: dict[str, list[ActorPart]] = {}
    for part in audit.parts:
        if part.attached:
            attached_by_role.setdefault(part.role, []).append(part)
    visible_drawables_by_role: dict[str, list[FaceDrawable]] = {}
    face_drawables = list(audit.face_drawables)
    if base_audit is not None and base_audit is not audit:
        face_drawables.extend(base_audit.face_drawables)
    for drawable in face_drawables:
        if drawable.node_mask not in {"0", "0x0"} and drawable.culling_active != "1":
            visible_drawables_by_role.setdefault(drawable.role, []).append(drawable)

    row["observed"] = {
        "editorId": audit.editor_id,
        "name": audit.name,
        "attachedRoles": {role: len(parts) for role, parts in sorted(attached_by_role.items())},
        "visibleFaceDrawableRoles": {role: len(parts) for role, parts in sorted(visible_drawables_by_role.items())},
        "faceCheck": audit.face_check,
        "hairVariants": audit.hair_variants,
    }

    for role, minimum in expected["roles"].items():
        actual = len(attached_by_role.get(role, []))
        if actual < minimum and not (role == "eyes" and len(attached_by_role.get("leftEye", [])) and len(attached_by_role.get("rightEye", []))):
            row["failures"].append({"field": f"part.{role}", "expectedAtLeast": minimum, "actual": actual})

    if expected["hairModel"]:
        actual_hair_models = sorted({part.model for part in attached_by_role.get("hair", [])})
        if expected["hairModel"] not in actual_hair_models:
            row["failures"].append(
                {"field": "hair.model", "expected": expected["hairModel"], "actual": actual_hair_models}
            )

    hair_drawables = visible_drawables_by_role.get("hair", [])
    beard_drawables = visible_drawables_by_role.get("beard", [])
    if beard_drawables and hair_drawables:
        beard = beard_drawables[0]
        hair = hair_drawables[0]
        if not close_rgb(beard.material_diffuse, hair.material_diffuse):
            row["failures"].append(
                {
                    "field": "hair.materialDiffuseMatchesBeard",
                    "expected": beard.material_diffuse,
                    "actual": hair.material_diffuse,
                }
            )
        if not close_rgb(beard.material_emission, hair.material_emission):
            row["failures"].append(
                {
                    "field": "hair.materialEmissionMatchesBeard",
                    "expected": beard.material_emission,
                    "actual": hair.material_emission,
                }
            )

    if audit.face_check:
        for key in ("head", "mouth", "lowerTeeth", "upperTeeth", "tongue", "leftEye", "rightEye", "hairAttached"):
            if audit.face_check.get(key) not in (None, "OK", "IN_HEAD"):
                row["failures"].append({"field": f"faceCheck.{key}", "actual": audit.face_check.get(key)})

        if audit.face_check.get("faceTexture") == "RACE+DETAIL":
            head_drawables = visible_drawables_by_role.get("head", [])
            final_head = head_drawables[-1] if head_drawables else None
            stages = final_head.texture_stages if final_head else ""
            row["observed"]["finalHeadLayerState"] = {
                "hasSkinAuxMap": "skinAuxMap" in stages,
                "hasFaceGenMap0": "faceGenMap0" in stages,
                "hasFaceGenMap1": "faceGenMap1" in stages,
                "usesNeutralFaceGen0": "neutral-facegen0" in stages,
                "usesNeutralFaceGen1": "neutral-facegen1" in stages,
            }
            if final_head is None:
                row["failures"].append({"field": "head.finalDrawable", "expected": "visible", "actual": "missing"})
            else:
                for map_name in ("skinAuxMap", "faceGenMap0", "faceGenMap1"):
                    if map_name not in stages:
                        row["failures"].append({"field": f"head.{map_name}", "expected": "bound", "actual": "missing"})
                if "neutral-facegen0" in stages:
                    row["failures"].append(
                        {"field": "head.faceGenMap0", "expected": "actor-specific", "actual": "neutral-facegen0"}
                    )
                if "neutral-facegen1" in stages:
                    row["failures"].append(
                        {"field": "head.faceGenMap1", "expected": "actor-specific", "actual": "neutral-facegen1"}
                    )

    row["status"] = "passed" if not row["failures"] else "failing"
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--openmw-log", type=Path)
    parser.add_argument(
        "--roundup-index",
        type=Path,
        help="Roundup index whose per-target log paths should be used for actor accounting.",
    )
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    if not args.openmw_log and not args.roundup_index:
        parser.error("one of --openmw-log or --roundup-index is required")

    matrix = load_json_auto(args.matrix)
    targets = [
        target
        for target in matrix.get("targets", [])
        if str(target.get("category", "")).endswith("humanoid")
    ]

    if args.roundup_index:
        roundup = load_json_auto(args.roundup_index)
        roundup_by_id = {row.get("id"): row for row in roundup.get("rows", [])}
        rows = []
        for target in targets:
            roundup_row = roundup_by_id.get(target.get("id"))
            log = Path(roundup_row.get("log", "")) if roundup_row else None
            if log and log.exists():
                rows.append(audit_target(target, load_openmw_actor_telemetry(log)))
            else:
                row = audit_target(target, {})
                row["failures"].append(
                    {
                        "field": "roundupLog",
                        "expected": "present",
                        "actual": str(log) if log else "missing-index-row",
                    }
                )
                row["status"] = "failing"
                rows.append(row)
    else:
        actors = load_openmw_actor_telemetry(args.openmw_log)
        rows = [audit_target(target, actors) for target in targets]
    counts = {
        status: sum(row["status"] == status for row in rows)
        for status in ("pending", "failing", "passed")
    }
    report = {
        "schema": "nikami-fnv-openmw-actor-part-accounting/v1",
        "matrix": str(args.matrix),
        "openmwLog": str(args.openmw_log) if args.openmw_log else None,
        "roundupIndex": str(args.roundup_index) if args.roundup_index else None,
        "counts": counts,
        "complete": counts["pending"] == 0 and counts["failing"] == 0,
        "rows": rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"counts": counts, "out": str(args.out)}, separators=(",", ":")))
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
