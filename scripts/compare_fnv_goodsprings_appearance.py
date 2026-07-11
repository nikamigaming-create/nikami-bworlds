#!/usr/bin/env python3
"""Compare Goodsprings xNVSE appearance events with authored ESM metadata."""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageStat


def form_int(value):
    if value in (None, ""):
        return 0
    return int(value, 16) if isinstance(value, str) else int(value)


def normalized_model(value):
    return (value or "").replace("/", "\\").lower()


def load_events(path):
    with path.open("r", encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def image_metrics(path):
    with Image.open(path) as image:
        grayscale = image.convert("L")
        stats = ImageStat.Stat(grayscale)
        width, height = image.size
        center = grayscale.crop((width // 4, height // 3, width * 3 // 4, height * 9 // 10))
        center_stats = ImageStat.Stat(center)
        return {
            "width": width,
            "height": height,
            "meanLuma": round(stats.mean[0], 3),
            "lumaStdDev": round(stats.stddev[0], 3),
            "centerMeanLuma": round(center_stats.mean[0], 3),
            "centerLumaStdDev": round(center_stats.stddev[0], 3),
        }


def compare_target(target, capture_path):
    expected_ref = form_int(target["reference"]["form"])
    result = {
        "id": target["id"],
        "reference": target["reference"]["form"],
        "capture": str(capture_path) if capture_path else None,
        "status": "pending",
        "mismatches": [],
    }
    if capture_path is None:
        return result
    screenshot_root = capture_path.with_suffix("").with_name(capture_path.stem + "-screens")
    screenshot_label = f"{expected_ref:08x}"
    raw_screenshot = screenshot_root / f"frame-target-{screenshot_label}.bmp"
    proof_crop = screenshot_root / f"frame-target-{screenshot_label}-proof-crop.png"
    result["rawScreenshot"] = str(raw_screenshot.resolve()) if raw_screenshot.is_file() else None
    result["proofCrop"] = str(proof_crop.resolve()) if proof_crop.is_file() else None
    events = load_events(capture_path)
    faults = [event for event in events if "fault" in event.get("event", "")]
    if faults:
        result["status"] = "failing"
        result["mismatches"].append({"field": "faults", "actual": [event["event"] for event in faults]})
        return result
    if not target["category"].endswith("humanoid"):
        event = next(
            (
                event
                for event in events
                if event.get("event") == "target-appearance" and event.get("refForm") == expected_ref
            ),
            None,
        )
        result["status"] = "captured" if event else "failing"
        if event is None:
            result["mismatches"].append({"field": "target-appearance", "actual": "missing"})
        return result

    event = next(
        (
            event
            for event in events
            if event.get("event") == "npc-appearance" and event.get("refForm") == expected_ref
        ),
        None,
    )
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
    if not raw_screenshot.is_file() or not proof_crop.is_file():
        result["mismatches"].append(
            {
                "field": "pixelEvidence",
                "expected": "raw BMP and proof crop",
                "actual": {
                    "raw": raw_screenshot.is_file(),
                    "proofCrop": proof_crop.is_file(),
                },
            }
        )
    else:
        metrics = image_metrics(proof_crop)
        result["pixelMetrics"] = metrics
        if metrics["width"] < 800 or metrics["height"] < 600:
            result["mismatches"].append(
                {"field": "pixelDimensions", "expected": ">=800x600", "actual": metrics}
            )
        if metrics["meanLuma"] < 3 or metrics["lumaStdDev"] < 3:
            result["mismatches"].append(
                {"field": "pixelReadiness", "expected": "rendered non-black frame", "actual": metrics}
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
        "screenshots": [
            {"target": row["id"], "path": row["proofCrop"]}
            for row in rows
            if row.get("proofCrop")
        ],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report["counts"], separators=(",", ":")))


if __name__ == "__main__":
    main()
