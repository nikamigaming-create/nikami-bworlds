#!/usr/bin/env python3
"""Compile effective QUST defaults plus a validated FNV save overlay for Godot."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def require(value: bool, message: str) -> None:
    if not value:
        raise ValueError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip().lower()
    if not text or text in {"0", "null"}:
        return ""
    return f"0x{int(text, 16) if text.startswith('0x') else int(text):08x}"


def compile_state(semantic_dir: Path, overlay_path: Path, output_path: Path) -> dict[str, Any]:
    manifest_path = semantic_dir / "manifest.json"
    quests_path = semantic_dir / "quests.json"
    scripts_path = semantic_dir / "scripts.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    quests_doc = json.loads(quests_path.read_text(encoding="utf-8"))
    scripts_doc = json.loads(scripts_path.read_text(encoding="utf-8"))
    overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    require(manifest.get("schema") == "opennv-semantic-database/v1", "invalid semantic manifest")
    require(quests_doc.get("schema") == "opennv-semantic-quests/v1", "invalid quest catalog")
    require(scripts_doc.get("schema") == "opennv-semantic-scripts/v1", "invalid script catalog")
    require(overlay.get("schema") == "opennv-fos-changeform-index/v1", "invalid save overlay")
    artifacts = {row["path"]: row for row in manifest.get("artifacts", [])}
    for name, path in (("quests.json", quests_path), ("scripts.json", scripts_path)):
        require(name in artifacts, f"semantic manifest omits {name}")
        require(artifacts[name]["sha256"] == sha256(path), f"stale semantic artifact {name}")

    scripts = {}
    for row in scripts_doc["scripts"]:
        script_id = canonical(row.get("id"))
        require(script_id and script_id not in scripts, f"duplicate script {script_id}")
        references = {int(value) for value in row.get("scriptLocalReferenceIndices", [])}
        locals_by_index = {}
        for local in row.get("scriptLocals", []):
            index = int(local["index"])
            require(index > 0, f"invalid local {script_id}:{index}")
            candidate = {"name": str(local.get("name", "")), "reference": index in references}
            if index in locals_by_index:
                require(locals_by_index[index] == candidate, f"conflicting duplicate local {script_id}:{index}")
                continue
            locals_by_index[index] = candidate
        scripts[script_id] = locals_by_index

    saved_quests = {}
    unmatched_saved = []
    for entry in overlay.get("changeForms", []):
        state = entry.get("questState")
        if not isinstance(state, dict):
            continue
        quest_id = canonical((entry.get("refId") or {}).get("resolvedFormId"))
        require(quest_id and quest_id not in saved_quests, f"duplicate saved quest {quest_id}")
        saved_quests[quest_id] = state

    quest_rows = {}
    running = completed = failed = stage_rows = objective_rows = 0
    variable_rows = saved_numeric = reference_locals = 0
    catalog_ids = set()
    for quest in quests_doc["quests"]:
        quest_id = canonical(quest.get("id"))
        require(quest_id and quest_id not in catalog_ids, f"duplicate quest {quest_id}")
        catalog_ids.add(quest_id)
        quest_data = quest.get("questData")
        require(isinstance(quest_data, dict) and "flags" in quest_data, f"quest {quest_id} lacks DATA")
        flags = int(quest_data["flags"]) & 0xFF
        saved = saved_quests.get(quest_id)
        if saved is not None and saved.get("flags") is not None:
            flags = int(saved["flags"]) & 0xFF
        stages = {}
        objectives = {}
        current_stage = 0
        if saved is not None:
            for stage in saved.get("stages", []):
                stage_id = int(stage["id"])
                require(str(stage_id) not in stages, f"duplicate saved stage {quest_id}:{stage_id}")
                done = bool(stage.get("done", False))
                stages[str(stage_id)] = done
                if done:
                    current_stage = max(current_stage, stage_id)
                stage_rows += 1
            for objective in saved.get("objectives", []):
                objective_id = int(objective["id"])
                require(str(objective_id) not in objectives, f"duplicate saved objective {quest_id}:{objective_id}")
                objectives[str(objective_id)] = int(objective["flags"])
                objective_rows += 1
        script_id = canonical(quest.get("script"))
        variables = {}
        if script_id:
            require(script_id in scripts, f"quest {quest_id} references missing script {script_id}")
            for index, local in scripts[script_id].items():
                if local["reference"]:
                    reference_locals += 1
                    continue
                variables[str(index)] = 0.0
                variable_rows += 1
        if saved is not None and isinstance(saved.get("scriptState"), dict):
            for variable in saved["scriptState"].get("variables", []):
                index = int(variable["index"])
                require(script_id and index in scripts[script_id], f"unknown saved quest local {quest_id}:{index}")
                if variable.get("kind") == "numeric":
                    variables[str(index)] = float(variable["value"])
                    saved_numeric += 1
        row = {
            "flags": flags,
            "currentStage": current_stage,
            "stageDone": stages,
            "objectives": objectives,
            "variables": variables,
            "script": script_id,
            "source": "save-overlay" if saved is not None else "authored-default",
        }
        quest_rows[quest_id] = row
        running += bool(flags & 0x01)
        completed += bool(flags & 0x02)
        failed += bool(flags & 0x40)
    unmatched_saved = sorted(set(saved_quests) - catalog_ids)
    result = {
        "schema": "opennv-quest-save-state/v1",
        "status": "pass" if not unmatched_saved else "partial",
        "provenance": {
            "semanticManifestSha256": sha256(manifest_path),
            "questsSha256": sha256(quests_path),
            "scriptsSha256": sha256(scripts_path),
            "saveOverlaySha256": sha256(overlay_path),
            "saveSha256": str((overlay.get("source") or {}).get("sha256", "")),
            "loadOrderSha256": manifest.get("load_order_sha256"),
        },
        "counts": {
            "quests": len(quest_rows),
            "savedQuestChangeForms": len(saved_quests),
            "unmatchedSavedQuestChangeForms": len(unmatched_saved),
            "running": running,
            "completed": completed,
            "failed": failed,
            "stageRows": stage_rows,
            "objectiveRows": objective_rows,
            "numericVariableDefaults": variable_rows,
            "savedNumericVariables": saved_numeric,
            "referenceLocalsExcluded": reference_locals,
        },
        "unmatchedSavedQuests": unmatched_saved,
        "quests": quest_rows,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--semantic-db", type=Path, required=True)
    parser.add_argument("--save-overlay", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compile_state(args.semantic_db, args.save_overlay, args.output)
    print("OPENNV_QUEST_SAVE_STATE " + json.dumps(result["counts"], sort_keys=True))
    return 0 if result["status"] in {"pass", "partial"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
