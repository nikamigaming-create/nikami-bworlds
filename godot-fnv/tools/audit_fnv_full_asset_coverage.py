#!/usr/bin/env python3
"""Prove every full-cell model is converted, adapted, or retail-missing."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


RETAIL_MISSING = {
    "architecture\\diner\\dinernosigntest.nif",
    "clutter\\heliosone\\nv_heliosone_solarreflectormetal_01.nif",
}


def classify_special(model: str) -> str:
    value = model.replace("/", "\\").lower()
    filename = value.rsplit("\\", 1)[-1]
    marker = (
        "marker" in filename or "shadow" in filename or "invisible" in filename
        or "nomesh" in filename or value.startswith("furniture\\") or "\\furniture\\" in value
    )
    if marker:
        return "authored-marker"
    effect = (
        value.startswith("effects\\") or value.startswith("fx\\") or "\\effects\\" in value
        or value.startswith("lights\\") or "light" in value or "glow" in value
        or "\\sky\\" in value or "rain" in value or value.endswith("skeleton.nif")
    )
    if effect:
        return "procedural-effect"
    if value in RETAIL_MISSING:
        return "retail-missing"
    return "unsupported"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text(encoding="utf-8"))
    converted_root = args.project_root / "generated" / "assets" / "converted"
    native_root = args.project_root / "generated" / "assets" / "native" / "meshes"
    rows: list[dict[str, object]] = []
    counts = {"converted": 0, "authored_marker": 0, "procedural_effect": 0, "retail_missing": 0, "unsupported": 0}
    seen: set[str] = set()
    for authored in inventory.get("models", []):
        model = str(authored).replace("/", "\\")
        canonical = model.lower()
        if canonical in seen:
            continue
        seen.add(canonical)
        relative = Path(model.replace("\\", "/"))
        obj = (converted_root / relative).with_suffix(".obj")
        sidecar = Path(str(obj) + ".textures.json")
        if obj.is_file() and sidecar.is_file():
            category = "converted"
        else:
            category = classify_special(model)
        key = category.replace("-", "_")
        counts[key] += 1
        if category != "converted":
            rows.append({
                "model": model,
                "category": category,
                "nativeExtracted": (native_root / relative).is_file(),
            })
    total = len(seen)
    conserved = sum(counts.values()) == total
    report = {
        "schema": "opennv-full-cell-asset-coverage/v1",
        "status": "pass" if conserved and total > 0 and counts["unsupported"] == 0 else "fail",
        "sourceInventory": str(args.inventory.resolve()),
        "counts": {"models": total, **counts},
        "specialModels": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_FULL_ASSET_COVERAGE " + json.dumps(report["counts"], sort_keys=True))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
