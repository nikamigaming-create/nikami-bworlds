#!/usr/bin/env python3
"""Extract every authored diffuse texture referenced by ONVSKEL1 actors."""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path

from decode_opennv_skeletal_actor import decode_bytes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload-root", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--bsatool", type=Path, required=True)
    args = parser.parse_args()
    archives = [
        *sorted(args.data_root.glob("* - Main.bsa")),
        args.data_root / "Update.bsa",
        args.data_root / "Fallout - Textures.bsa",
        args.data_root / "Fallout - Textures2.bsa",
    ]
    archives = [path for path in dict.fromkeys(archives) if path.is_file()]
    for required in [args.bsatool, *archives]:
        if not required.is_file():
            raise FileNotFoundError(required)
    payloads = sorted(args.payload_root.rglob("actor-*.onvskel"))
    if not payloads:
        raise RuntimeError(f"No ONVSKEL1 payloads found under {args.payload_root}")
    textures: set[str] = set()
    for payload in payloads:
        audit = decode_bytes(payload.read_bytes())
        textures.update(
            str(surface["texture"]).replace("/", "\\").lstrip("\\").lower()
            for surface in audit["surfaces"]
            if surface["texture"]
        )
    output_root = args.project_root / "generated" / "assets" / "converted"
    extracted = 0
    for relative in sorted(textures):
        target = output_root / Path(relative.replace("\\", os.sep))
        if target.is_file():
            continue
        for archive in archives:
            subprocess.run(
                [str(args.bsatool), "extract", "-f", str(archive), relative, str(output_root)],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if target.is_file():
                extracted += 1
                break
        if not target.is_file():
            raise RuntimeError(f"Authored skeletal actor texture was not found: {relative}")
    print(
        f"OPENNV_SKELETAL_TEXTURES_READY payloads={len(payloads)} "
        f"textures={len(textures)} extracted={extracted}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
