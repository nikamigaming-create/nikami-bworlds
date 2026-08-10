#!/usr/bin/env python3
"""Reduce the authoritative OpenMW FOS decode to a Godot boot contract."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def value(node, default=None):
    return node.get("value", default) if isinstance(node, dict) else default


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--normalized-save", type=Path, required=True)
    parser.add_argument("--save", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    decoded = json.loads(args.normalized_save.read_text(encoding="utf-8"))
    save_bytes = args.save.read_bytes()
    actual_hash = hashlib.sha256(save_bytes).hexdigest()
    expected_hash = str(decoded["source"]["sha256"]).lower()
    if actual_hash != expected_hash:
        raise SystemExit(f"save hash disagrees with decoder: {actual_hash} != {expected_hash}")

    position = [float(value(item, 0.0)) for item in decoded["transform"]["position"]]
    rotation = [float(value(item, 0.0)) for item in decoded["transform"]["rotationRadians"]]
    inventory = [
        {"form_id": row["formId"], "count": int(row["count"])}
        for row in decoded["inventory"]["finalTotals"]
        if int(row["count"]) > 0
    ]
    result = {
        "schema": "nikami-open-nv-godot-bootstrap/v1",
        "status": "save-backed-bootstrap",
        "save": {
            "path": str(args.save.resolve()).replace("\\", "/"),
            "bytes": len(save_bytes),
            "sha256": actual_hash,
        },
        "data_root": str(args.data_root.resolve()).replace("\\", "/"),
        "load_order": [row["name"] for row in decoded["masters"]],
        "player": {
            "base_form_id": value(decoded["player"]["baseRecord"]),
            "reference_form_id": value(decoded["player"]["referenceRecord"]),
            "save_number": value(decoded["player"]["saveNumber"]),
            "name": value(decoded["player"]["name"], ""),
            "karma_title": value(decoded["player"]["karmaTitle"], ""),
            "level": value(decoded["player"]["level"], 1),
            "location": value(decoded["player"]["locationLabel"], ""),
            "play_time": value(decoded["player"]["playTimeLabel"], ""),
            "weapon_drawn": value(decoded["player"]["weaponDrawn"], False),
        },
        "world": {
            "form_id": value(decoded["transform"]["cellOrWorldspace"]),
            "record_family": decoded["transform"]["cellOrWorldspace"].get("recordFamily"),
            "source_position": position,
            "source_rotation_radians": rotation,
            "cell_grid": [int(position[0] // 4096.0), int(position[1] // 4096.0)],
            "godot_floating_origin_position": [0.0, 0.0, 0.0],
            "bethesda_units_per_meter": 70.0,
        },
        "camera": {
            "first_person": bool(value(decoded["camera"]["firstPerson"], True)),
            "world_fov": float(value(decoded["camera"]["worldFov"], 75.0)),
            "model_fov": float(value(decoded["camera"]["firstPersonModelFov"], 55.0)),
        },
        "scene": {
            "game_hour": float(value(decoded["scene"]["gameHour"], 12.0)),
            "current_weather": value(decoded["scene"]["currentWeather"]),
            "default_weather": value(decoded["scene"]["defaultWeather"]),
        },
        "inventory": inventory,
        "equipped": decoded.get("equippedRows", {}),
        "quest_progress": decoded.get("questProgress", {}),
        "globals": decoded.get("globals", []),
        "decode_boundary": decoded.get("normalizedLoadPlan", {}).get("uncoveredState", []),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(
        "OPENNV_GODOT_MANIFEST "
        f"save={result['player']['save_number']} location={result['player']['location']} "
        f"masters={len(result['load_order'])} inventory={len(inventory)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

