#!/usr/bin/env python3
"""Census authored PACK conditions against the fail-closed Godot evaluator."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


RUNTIME_FUNCTIONS = {18, 35, 46, 49, 50, 56, 58, 59, 72, 74, 77, 79, 80, 84, 91, 110, 136, 420, 421, 546}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    document = json.loads(args.input.read_text(encoding="utf-8"))
    if document.get("schema") != "opennv-semantic-actor-packages/v1":
        raise SystemExit("unexpected actor package schema")
    packages = document.get("packages", [])
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
    covered = sum(count for function_id, count in functions.items() if function_id in RUNTIME_FUNCTIONS)
    unsupported_rows = [
        {"functionId": function_id, "conditions": count}
        for function_id, count in sorted(functions.items(), key=lambda row: (-row[1], row[0]))
        if function_id not in RUNTIME_FUNCTIONS
    ]
    report = {
        "schema": "opennv-package-condition-audit/v1",
        "status": "pass" if layouts.get("unsupported", 0) == 0 else "fail",
        "counts": {
            "packages": len(packages),
            "conditionalPackages": conditional_packages,
            "conditions": total,
            "runtimeCoveredConditions": covered,
            "runtimeUnsupportedConditions": total - covered,
            "runtimeCoveragePercent": round(100.0 * covered / total, 3) if total else 100.0,
            "unsupportedLayouts": layouts.get("unsupported", 0),
        },
        "supportedFunctionIds": sorted(RUNTIME_FUNCTIONS),
        "unsupportedFunctions": unsupported_rows,
        "functionCensus": [
            {"functionId": function_id, "conditions": count, "runtimeSupported": function_id in RUNTIME_FUNCTIONS}
            for function_id, count in sorted(functions.items(), key=lambda row: (-row[1], row[0]))
        ],
        "policy": "Unsupported conditions fail closed; coverage is reported, never inferred.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        "OPENNV_PACKAGE_CONDITION_AUDIT "
        f"status={report['status']} conditions={total} covered={covered} "
        f"unsupported={total - covered} coverage={report['counts']['runtimeCoveragePercent']}%"
    )
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
