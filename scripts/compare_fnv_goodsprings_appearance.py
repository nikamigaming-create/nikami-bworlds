#!/usr/bin/env python3
"""Compare Goodsprings xNVSE appearance events with authored ESM metadata."""

import argparse
import json
from pathlib import Path


def form_int(value):
    if value in (None, ""):
        return 0
    return int(value, 16) if isinstance(value, str) else int(value)


def normalized_model(value):
    return (value or "").replace("/", "\\").lower()


def load_events(path):
    with path.open("r", encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def compare_target(target, capture_path):
    result = {
        "id": target["id"],
        "reference": target["reference"]["form"],
        "capture": str(capture_path) if capture_path else None,
        "status": "pending",
        "mismatches": [],
    }
    if capture_path is None:
        return result
    events = load_events(capture_path)
    faults = [event for event in events if "fault" in event.get("event", "")]
    if faults:
        result["status"] = "failing"
        result["mismatches"].append({"field": "faults", "actual": [event["event"] for event in faults]})
        return result
    if not target["category"].endswith("humanoid"):
        event = next((event for event in events if event.get("event") == "target-appearance"), None)
        result["status"] = "captured" if event else "failing"
        if event is None:
            result["mismatches"].append({"field": "target-appearance", "actual": "missing"})
        return result

    event = next((event for event in events if event.get("event") == "npc-appearance"), None)
    if event is None:
        result["status"] = "failing"
        result["mismatches"].append({"field": "npc-appearance", "actual": "missing"})
        return result

    expected = target["appearance"]["effectiveTraits"]
    checks = {
        "refForm": form_int(target["reference"]["form"]),
        "baseForm": form_int(target["base"]["form"]),
        "raceForm": form_int(expected.get("race", {}).get("form")),
        "hairForm": form_int(expected.get("hair", {}).get("form")),
        "eyesForm": form_int(expected.get("eyes", {}).get("form")),
        "hairColorRgba": expected.get("hairColorRgba"),
    }
    for field, expected_value in checks.items():
        if event.get(field) != expected_value:
            result["mismatches"].append(
                {"field": field, "expected": expected_value, "actual": event.get(field)}
            )

    expected_length = expected.get("hairLength")
    if expected_length is not None and abs(event.get("hairLength", -999.0) - expected_length) > 1e-5:
        result["mismatches"].append(
            {"field": "hairLength", "expected": expected_length, "actual": event.get("hairLength")}
        )

    expected_parts = sorted(form_int(part.get("form")) for part in expected.get("headParts", []))
    actual_parts = sorted(form_int(part.get("form")) for part in event.get("headParts", []))
    if actual_parts != expected_parts:
        result["mismatches"].append(
            {"field": "headParts", "expected": expected_parts, "actual": actual_parts}
        )

    expected_hair_model = normalized_model((expected.get("hair") or {}).get("models", [""])[0])
    actual_hair_model = normalized_model(event.get("hairModel"))
    if expected_hair_model != actual_hair_model:
        result["mismatches"].append(
            {"field": "hairModel", "expected": expected_hair_model, "actual": actual_hair_model}
        )

    if len(event.get("raceFaceSlots", [])) != 8:
        result["mismatches"].append(
            {"field": "raceFaceSlots", "expectedCount": 8, "actualCount": len(event.get("raceFaceSlots", []))}
        )
    result["status"] = "passed" if not result["mismatches"] else "failing"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--capture", action="append", default=[], metavar="TARGET=JSONL")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    matrix = json.loads(args.matrix.read_text(encoding="utf-8"))
    captures = {}
    for item in args.capture:
        target_id, separator, path = item.partition("=")
        if not separator or not target_id or not path:
            raise SystemExit(f"Expected --capture TARGET=JSONL, got: {item}")
        capture_path = Path(path)
        if not capture_path.is_file():
            raise SystemExit(f"Missing capture: {capture_path}")
        captures[target_id] = capture_path

    rows = [compare_target(target, captures.get(target["id"])) for target in matrix["targets"]]
    counts = {status: sum(row["status"] == status for row in rows) for status in ("pending", "captured", "failing", "passed")}
    report = {
        "schema": "nikami-fnv-goodsprings-appearance-differential/v1",
        "matrix": str(args.matrix),
        "counts": counts,
        "complete": counts["pending"] == 0 and counts["failing"] == 0,
        "rows": rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report["counts"], separators=(",", ":")))


if __name__ == "__main__":
    main()
