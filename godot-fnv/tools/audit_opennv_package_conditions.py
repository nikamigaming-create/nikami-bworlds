#!/usr/bin/env python3
"""Census authored PACK conditions against the fail-closed Godot evaluator."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


RUNTIME_FUNCTIONS = {1, 18, 32, 35, 46, 49, 50, 56, 58, 59, 64, 67, 72, 74, 77, 79, 80, 84, 91, 110, 136, 300, 310, 420, 421, 546}
QUEST_FUNCTIONS = {56, 58, 59, 79, 420, 421, 546}


def canonical_form_id(value: object) -> str:
    if isinstance(value, int):
        return f"0x{value:08x}"
    text = str(value or "").strip().lower()
    if not text:
        return ""
    try:
        return f"0x{int(text, 16):08x}"
    except ValueError:
        return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--script-variable-save-state", type=Path)
    parser.add_argument("--quest-save-state", type=Path)
    args = parser.parse_args()

    document = json.loads(args.input.read_text(encoding="utf-8"))
    if document.get("schema") != "opennv-semantic-actor-packages/v1":
        raise SystemExit("unexpected actor package schema")
    packages = document.get("packages", [])
    function53_live_rows = 0
    quest_ids: set[str] = set()
    if args.script_variable_save_state:
        state = json.loads(args.script_variable_save_state.read_text(encoding="utf-8"))
        counts = state.get("counts", {})
        state_valid = (
            state.get("schema") == "opennv-script-variable-save-state/v1"
            and state.get("status") in ("pass", "partial")
            and int(counts.get("failures", -1)) == 0
        )
        if state_valid:
            function53_live_rows = int(counts.get("operationalResolvedExplicitRows", 0))
    if args.quest_save_state:
        state = json.loads(args.quest_save_state.read_text(encoding="utf-8"))
        if state.get("schema") == "opennv-quest-save-state/v1" and state.get("status") in ("pass", "partial"):
            quest_ids = {canonical_form_id(key) for key in state.get("quests", {})}
    functions: Counter[int] = Counter()
    layouts: Counter[str] = Counter()
    conditional_packages = 0
    for package in packages:
        conditions = package.get("conditionData", [])
        if conditions:
            conditional_packages += 1
        for condition in conditions:
            function_id = int(condition.get("functionId", -1))
            functions[function_id] += 1
            layouts["supported" if condition.get("supportedLayout") else "unsupported"] += 1

    total = sum(functions.values())
    function53_explicit = sum(
        1 for package in packages for condition in package.get("conditionData", [])
        if int(condition.get("functionId", -1)) == 53
        and bool(condition.get("param1IsForm")) and condition.get("param1")
    )
    covered_by_function = Counter({function_id: count for function_id, count in functions.items() if function_id in RUNTIME_FUNCTIONS})
    if function53_live_rows:
        covered_by_function[53] = min(function53_explicit, function53_live_rows)
    quest_rows = [
        condition for package in packages for condition in package.get("conditionData", [])
        if int(condition.get("functionId", -1)) in QUEST_FUNCTIONS
    ]
    quest_rows_resolved = sum(
        1 for condition in quest_rows
        if bool(condition.get("param1IsForm"))
        and canonical_form_id(condition.get("param1")) in quest_ids
    )
    for function_id in QUEST_FUNCTIONS:
        rows = [condition for condition in quest_rows if int(condition.get("functionId", -1)) == function_id]
        covered_by_function[function_id] = sum(
            1 for condition in rows
            if bool(condition.get("param1IsForm"))
            and canonical_form_id(condition.get("param1")) in quest_ids
        )
    covered = sum(covered_by_function.values())
    unsupported_rows = [
        {"functionId": function_id, "conditions": count - covered_by_function.get(function_id, 0)}
        for function_id, count in sorted(functions.items(), key=lambda row: (-row[1], row[0]))
        if covered_by_function.get(function_id, 0) != count
    ]
    report = {
        "schema": "opennv-package-condition-audit/v1",
        "status": "pass" if layouts.get("unsupported", 0) == 0 else "fail",
        "counts": {
            "packages": len(packages),
            "conditionalPackages": conditional_packages,
            "conditions": total,
            "implementedFunctionConditions": covered,
            "unimplementedFunctionConditions": total - covered,
            "implementedFunctionCoveragePercent": round(100.0 * covered / total, 3) if total else 100.0,
            "unsupportedLayouts": layouts.get("unsupported", 0),
        },
        "supportedFunctionIds": sorted(RUNTIME_FUNCTIONS),
        "unsupportedFunctions": unsupported_rows,
        "functionCensus": [
            {"functionId": function_id, "conditions": count,
             "runtimeSupportedConditions": covered_by_function.get(function_id, 0),
             "runtimeSupported": covered_by_function.get(function_id, 0) == count}
            for function_id, count in sorted(functions.items(), key=lambda row: (-row[1], row[0]))
        ],
        "policy": "Unsupported conditions fail closed; coverage is reported, never inferred.",
        "partialFunctionCoverage": {
            "53": {
                "explicitReferenceConditions": function53_explicit,
                "nullReferenceConditions": functions.get(53, 0) - function53_explicit,
                "liveSaveProviderRows": function53_live_rows,
            },
            "quest": {
                "conditions": len(quest_rows),
                "resolvedQuestConditions": quest_rows_resolved,
                "nullOrUnknownQuestConditions": len(quest_rows) - quest_rows_resolved,
                "saveStateQuestRecords": len(quest_ids),
            },
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        "OPENNV_PACKAGE_CONDITION_AUDIT "
        f"status={report['status']} conditions={total} covered={covered} "
        f"unsupported={total - covered} coverage={report['counts']['implementedFunctionCoveragePercent']}%"
    )
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
