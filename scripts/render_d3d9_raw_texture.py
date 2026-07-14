#!/usr/bin/env python3
"""Render a quarantined D3D9 texture readback without copying retail payloads into source.

The retail oracle stores texture levels without a DDS header.  This helper wraps
DXT1/DXT5 payloads in-memory so Pillow can decode them, or decodes A8R8G8B8
directly.  Only the requested PNG proof is written.
"""

from __future__ import annotations

import argparse
import io
import struct
from pathlib import Path

from PIL import Image


FOURCC = {
    "dxt1": b"DXT1",
    "dxt5": b"DXT5",
}


def dds_header(width: int, height: int, mip_count: int, fourcc: bytes, top_bytes: int) -> bytes:
    ddsd_caps = 0x1
    ddsd_height = 0x2
    ddsd_width = 0x4
    ddsd_pixel_format = 0x1000
    ddsd_linear_size = 0x80000
    ddsd_mipmap_count = 0x20000
    flags = ddsd_caps | ddsd_height | ddsd_width | ddsd_pixel_format | ddsd_linear_size
    caps = 0x1000  # DDSCAPS_TEXTURE
    if mip_count > 1:
        flags |= ddsd_mipmap_count
        caps |= 0x8 | 0x400000  # COMPLEX | MIPMAP
    pixel_format = struct.pack("<II4sIIIII", 32, 0x4, fourcc, 0, 0, 0, 0, 0)
    return b"DDS " + struct.pack(
        "<IIIIIII11I", 124, flags, height, width, top_bytes, 0, mip_count, *([0] * 11)
    ) + pixel_format + struct.pack("<IIIII", caps, 0, 0, 0, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--mips", type=int, default=1)
    parser.add_argument("--format", required=True, choices=["dds", "dxt1", "dxt5", "a8r8g8b8"])
    args = parser.parse_args()

    payload = args.input.read_bytes()
    if args.format == "dds":
        with Image.open(args.input) as decoded:
            image = decoded.convert("RGBA")
    elif args.format == "a8r8g8b8":
        needed = args.width * args.height * 4
        if len(payload) < needed:
            raise SystemExit(f"A8R8G8B8 payload is short: {len(payload)} < {needed}")
        image = Image.frombytes("RGBA", (args.width, args.height), payload[:needed], "raw", "BGRA")
    else:
        block_bytes = 8 if args.format == "dxt1" else 16
        top_bytes = max(1, (args.width + 3) // 4) * max(1, (args.height + 3) // 4) * block_bytes
        wrapped = dds_header(args.width, args.height, args.mips, FOURCC[args.format], top_bytes) + payload
        with Image.open(io.BytesIO(wrapped)) as decoded:
            image = decoded.convert("RGBA")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.output)
    print(f"rendered={args.output.resolve()} size={image.width}x{image.height} mode={image.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
