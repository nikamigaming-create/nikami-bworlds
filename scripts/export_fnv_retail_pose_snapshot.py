#!/usr/bin/env python3
"""Export an xNVSE actor-frame as an IEEE-754 pose replay contract."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path
from typing import Any


SCHEMA = "NIKAMI_RETAIL_POSE_SNAPSHOT_V1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle", type=Path, required=True)
    parser.add_argument("--frame", type=int, required=True)
    parser.add_argument("--ref-form", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def f32_bits(value: Any) -> str:
    bits = struct.unpack("<I", struct.pack("<f", float(value)))[0]
    return f"0x{bits:08X}"


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def load_actor_frame(path: Path, frame: int, ref_form: int) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as source:
        for line_number, raw in enumerate(source, start=1):
            if not raw.strip():
                continue
            event = json.loads(raw)
            if (
                event.get("event") == "actor-frame"
                and int(event.get("frame", -1)) == frame
                and int(event.get("refForm", -1)) == ref_form
            ):
                event["_lineNumber"] = line_number
                matches.append(event)
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected exactly one actor-frame frame={frame} ref=0x{ref_form:08X}; found {len(matches)}"
        )
    return matches[0]


def transform_bits(transform: dict[str, Any], prefix: str) -> list[str]:
    rotation = transform[f"{prefix}Rotation"]
    translation = transform[f"{prefix}Translation"]
    scale = transform[f"{prefix}Scale"]
    if len(rotation) != 9 or len(translation) != 3:
        raise RuntimeError(f"Malformed {prefix} transform: {transform}")
    return [*(f32_bits(value) for value in rotation), *(f32_bits(value) for value in translation), f32_bits(scale)]


def main() -> int:
    args = parse_args()
    event = load_actor_frame(args.oracle, args.frame, args.ref_form)

    position = event.get("position")
    rotation = event.get("rotation")
    bones = event.get("bones")
    if not isinstance(position, list) or len(position) != 3:
        raise RuntimeError("Actor frame has no three-component position")
    if not isinstance(rotation, list) or len(rotation) != 3:
        raise RuntimeError("Actor frame has no three-component rotation")
    if not isinstance(bones, list):
        raise RuntimeError("Actor frame has no bone array")

    selected: dict[str, dict[str, Any]] = {}
    for bone in bones:
        name = str(bone.get("name", ""))
        if name == "Scene Root" or name.lower().startswith("bip01"):
            if name in selected:
                raise RuntimeError(f"Duplicate retail skeleton node name: {name}")
            selected[name] = bone
    if "Scene Root" not in selected or "Bip01 Head" not in selected:
        raise RuntimeError("Retail frame does not contain Scene Root and Bip01 Head")

    lines = [
        SCHEMA,
        "source "
        + quoted(str(args.oracle.resolve()))
        + f" line {event['_lineNumber']} frame {args.frame} ref 0x{args.ref_form:08X}",
        "root " + " ".join(f32_bits(value) for value in [*position, *rotation]),
    ]
    for name, bone in selected.items():
        transform = bone.get("transform")
        if not isinstance(transform, dict):
            raise RuntimeError(f"Retail skeleton node has no transform: {name}")
        local = transform_bits(transform, "local")
        world = transform_bits(transform, "world")
        parent = str(bone.get("parentName", ""))
        lines.append(
            "node "
            + quoted(name)
            + " parent "
            + quoted(parent)
            + " local "
            + " ".join(local)
            + " world "
            + " ".join(world)
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "oracle": str(args.oracle.resolve()),
                "frame": args.frame,
                "refForm": f"0x{args.ref_form:08X}",
                "nodes": len(selected),
                "output": str(args.output.resolve()),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
