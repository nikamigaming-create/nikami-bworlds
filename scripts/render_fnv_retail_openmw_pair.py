#!/usr/bin/env python3
"""Render a hash-accounted retail frame beside an OpenMW screenshot.

The retail input may be a raw BGRA framebuffer or the RGB24 screenshot embedded
in the pinned Save330 .fos.  The tool never launches either game and never grants
visual acceptance: it only creates a review artifact and an optional provenance
manifest.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat


SAVE330_BYTES = 3_395_328
SAVE330_SHA256 = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
SAVE330_SCREENSHOT_OFFSET = 147
SAVE330_SCREENSHOT_WIDTH = 512
SAVE330_SCREENSHOT_HEIGHT = 320


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_retail(args: argparse.Namespace) -> tuple[Image.Image, dict[str, object]]:
    if args.retail_save:
        raw_save = args.retail_save.read_bytes()
        actual_hash = sha256_bytes(raw_save)
        if len(raw_save) != SAVE330_BYTES:
            raise RuntimeError(f"Save330 byte count is {len(raw_save)}, expected {SAVE330_BYTES}")
        if actual_hash != SAVE330_SHA256:
            raise RuntimeError(f"Save330 SHA-256 is {actual_hash}, expected {SAVE330_SHA256}")
        width = args.width or SAVE330_SCREENSHOT_WIDTH
        height = args.height or SAVE330_SCREENSHOT_HEIGHT
        expected = width * height * 3
        begin = args.retail_save_offset
        end = begin + expected
        if end > len(raw_save):
            raise RuntimeError(f"Save330 screenshot range {begin}+{expected} crosses EOF")
        payload = raw_save[begin:end]
        return Image.frombytes("RGB", (width, height), payload, "raw", "RGB"), {
            "kind": "pinned-save330-rgb24",
            "path": str(args.retail_save.resolve()).replace("\\", "/"),
            "bytes": len(raw_save),
            "sha256": actual_hash,
            "screenshotOffset": begin,
            "screenshotBytes": expected,
            "pixelFormat": "rgb24",
        }

    width = args.width or 2048
    height = args.height or 1280
    raw = args.retail_bgra.read_bytes()
    expected = width * height * 4
    if len(raw) != expected:
        raise RuntimeError(f"Retail byte count is {len(raw)}, expected {expected}")
    return Image.frombytes("RGBA", (width, height), raw, "raw", "BGRA").convert("RGB"), {
        "kind": "raw-bgra-framebuffer",
        "path": str(args.retail_bgra.resolve()).replace("\\", "/"),
        "bytes": len(raw),
        "sha256": sha256_bytes(raw),
        "pixelFormat": "bgra32",
    }


def image_metrics(retail: Image.Image, openmw: Image.Image) -> dict[str, object]:
    difference = ImageChops.difference(retail, openmw)
    difference_stats = ImageStat.Stat(difference)
    openmw_stats = ImageStat.Stat(openmw.convert("L"))
    return {
        "meanAbsoluteChannelDifference": [round(value, 6) for value in difference_stats.mean],
        "rootMeanSquareChannelDifference": [round(value, 6) for value in difference_stats.rms],
        "openmwLumaMean": round(openmw_stats.mean[0], 6),
        "openmwLumaStdDev": round(openmw_stats.stddev[0], 6),
    }


def add_labels(pair: Image.Image, left: str, right: str, height: int) -> Image.Image:
    if height <= 0:
        return pair
    labelled = Image.new("RGB", (pair.width, pair.height + height), "black")
    labelled.paste(pair, (0, height))
    draw = ImageDraw.Draw(labelled)
    draw.rectangle((pair.width // 2, 0, pair.width, height), fill=(122, 0, 0))
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", max(12, height // 2))
    except OSError:
        font = ImageFont.load_default()
    draw.text((10, max(1, height // 5)), left, fill="white", font=font)
    draw.text((pair.width // 2 + 10, max(1, height // 5)), right, fill="white", font=font)
    return labelled


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    retail_group = parser.add_mutually_exclusive_group(required=True)
    retail_group.add_argument("--retail-bgra", type=Path)
    retail_group.add_argument("--retail-save", type=Path)
    parser.add_argument("--openmw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--retail-output", type=Path)
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--retail-save-offset", type=int, default=SAVE330_SCREENSHOT_OFFSET)
    parser.add_argument(
        "--openmw-crop",
        type=int,
        nargs=4,
        metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"),
        help="Crop applied only to the OpenMW source before size validation",
    )
    parser.add_argument(
        "--fit-openmw",
        action="store_true",
        help="Resize the cropped OpenMW source to the retail dimensions",
    )
    parser.add_argument(
        "--crop",
        type=int,
        nargs=4,
        metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"),
        help="Optional identical source-pixel crop applied before pairing",
    )
    parser.add_argument("--left-label", default="")
    parser.add_argument("--right-label", default="")
    parser.add_argument("--label-height", type=int, default=0)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--status", choices=("rejected", "pending", "candidate"), default="rejected")
    parser.add_argument(
        "--source-provenance",
        type=Path,
        help="Required existing run manifest when status is candidate",
    )
    args = parser.parse_args()

    if args.status == "candidate" and (not args.source_provenance or not args.source_provenance.is_file()):
        raise RuntimeError("Candidate OpenMW frames require an existing --source-provenance manifest")

    retail, retail_provenance = load_retail(args)
    if args.retail_output:
        args.retail_output.parent.mkdir(parents=True, exist_ok=True)
        retail.save(args.retail_output, format="PNG", optimize=False)
    with Image.open(args.openmw) as source:
        openmw = source.convert("RGB")
    if args.openmw_crop:
        openmw = openmw.crop(tuple(args.openmw_crop))
    if args.fit_openmw and openmw.size != retail.size:
        openmw = openmw.resize(retail.size, Image.Resampling.LANCZOS)
    if openmw.size != retail.size:
        raise RuntimeError(f"Image sizes differ: retail={retail.size}, OpenMW={openmw.size}")

    if args.crop:
        box = tuple(args.crop)
        retail = retail.crop(box)
        openmw = openmw.crop(box)

    metrics = image_metrics(retail, openmw)
    pair = Image.new("RGB", (retail.width * 2, retail.height))
    pair.paste(retail, (0, 0))
    pair.paste(openmw, (retail.width, 0))
    pair = add_labels(pair, args.left_label, args.right_label, args.label_height)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    pair.save(args.output, format="PNG", optimize=False)

    if args.manifest:
        provenance = None
        if args.source_provenance:
            provenance = {
                "path": str(args.source_provenance.resolve()).replace("\\", "/"),
                "sha256": sha256_file(args.source_provenance),
            }
        manifest = {
            "schema": "nikami-fnv-retail-openmw-visual-pair/v1",
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "status": args.status,
            "accepted": False,
            "visualReviewRequired": True,
            "retail": retail_provenance,
            "openmw": {
                "path": str(args.openmw.resolve()).replace("\\", "/"),
                "bytes": args.openmw.stat().st_size,
                "sha256": sha256_file(args.openmw),
                "crop": args.openmw_crop,
                "fitToRetail": args.fit_openmw,
                "sourceProvenance": provenance,
            },
            "comparison": {
                "width": retail.width,
                "height": retail.height,
                "metrics": metrics,
            },
            "output": {
                "path": str(args.output.resolve()).replace("\\", "/"),
                "bytes": args.output.stat().st_size,
                "sha256": sha256_file(args.output),
            },
        }
        if args.retail_output:
            manifest["retail"]["extractedPng"] = {
                "path": str(args.retail_output.resolve()).replace("\\", "/"),
                "bytes": args.retail_output.stat().st_size,
                "sha256": sha256_file(args.retail_output),
            }
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
