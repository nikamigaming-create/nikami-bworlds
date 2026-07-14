#!/usr/bin/env python3
"""Render a raw retail BGRA framebuffer beside an unmodified OpenMW screenshot."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retail-bgra", type=Path, required=True)
    parser.add_argument("--openmw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=2048)
    parser.add_argument("--height", type=int, default=1280)
    parser.add_argument(
        "--crop",
        type=int,
        nargs=4,
        metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"),
        help="Optional identical source-pixel crop applied before pairing",
    )
    args = parser.parse_args()

    raw = args.retail_bgra.read_bytes()
    expected = args.width * args.height * 4
    if len(raw) != expected:
        raise RuntimeError(f"Retail byte count is {len(raw)}, expected {expected}")
    retail = Image.frombytes("RGBA", (args.width, args.height), raw, "raw", "BGRA").convert("RGB")
    with Image.open(args.openmw) as source:
        openmw = source.convert("RGB")
    if openmw.size != retail.size:
        raise RuntimeError(f"Image sizes differ: retail={retail.size}, OpenMW={openmw.size}")

    if args.crop:
        box = tuple(args.crop)
        retail = retail.crop(box)
        openmw = openmw.crop(box)

    pair = Image.new("RGB", (retail.width * 2, retail.height))
    pair.paste(retail, (0, 0))
    pair.paste(openmw, (retail.width, 0))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    pair.save(args.output, format="PNG", optimize=False)
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
