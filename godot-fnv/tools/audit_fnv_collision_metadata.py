#!/usr/bin/env python3
"""Fast gate for converted NIF collision sidecars."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--converted-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    failures: list[str] = []
    colliding = 0
    noncolliding = 0
    sidecars = sorted(args.converted_root.rglob("*.obj.textures.json"))
    for path in sidecars:
        try:
            row = json.loads(path.read_text(encoding="utf-8"))
            render = row.get("render_surfaces")
            collision = row.get("collision_surfaces")
            if row.get("collision_mode") != "openmw-bsx-render-geometry-v1":
                raise ValueError("missing collision mode")
            if not isinstance(render, list) or not isinstance(collision, list) or len(render) != len(collision):
                raise ValueError("render/collision surface census mismatch")
            if any(collision):
                colliding += 1
            else:
                noncolliding += 1
        except Exception as exc:
            failures.append(f"{path.relative_to(args.converted_root).as_posix()}: {exc}")

    report = {
        "schema": "nikami-open-nv-collision-metadata-audit/v1",
        "status": "pass" if sidecars and colliding and noncolliding and not failures else "fail",
        "counts": {
            "sidecars": len(sidecars),
            "colliding_models": colliding,
            "noncolliding_models": noncolliding,
            "failures": len(failures),
        },
        "failures": failures,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_COLLISION_AUDIT " + json.dumps(report["counts"], sort_keys=True))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
