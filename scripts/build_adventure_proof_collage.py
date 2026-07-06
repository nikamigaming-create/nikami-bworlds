#!/usr/bin/env python3
import argparse
import csv
import json
import shutil
from collections import Counter
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


WORLD_ORDER = [
    "morrowind",
    "oblivion",
    "fallout3",
    "fallout_new_vegas",
    "skyrim_vr",
    "fallout4_vr",
    "starfield",
]

CATEGORY_ORDER = [
    "usual_suspects",
    "adult_male",
    "adult_female",
    "child",
    "guard_or_soldier",
    "robot",
    "animal",
    "creature",
    "monster",
]

WORLD_SHORT = {
    "morrowind": "MW",
    "oblivion": "OB",
    "fallout3": "FO3",
    "fallout_new_vegas": "FNV",
    "skyrim_vr": "SKVR",
    "fallout4_vr": "FO4VR",
    "starfield": "SF",
}

STATUS_COLOR = {
    "screenshot": (58, 150, 83),
    "rejected-screenshot": (204, 146, 43),
    "rejected-telemetry-screenshot": (204, 103, 43),
    "crash-dump-no-screenshot": (178, 53, 53),
    "no-screenshot": (120, 120, 120),
    "manifest-error": (178, 53, 53),
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def parse_target_slug(target_dir: Path):
    name = target_dir.name
    for world_id in sorted(WORLD_ORDER, key=len, reverse=True):
        prefix = f"{world_id}-"
        if not name.startswith(prefix):
            continue
        rest = name[len(prefix) :]
        for category_id in CATEGORY_ORDER:
            category_prefix = f"{category_id}-"
            if rest.startswith(category_prefix):
                return world_id, category_id, rest[len(category_prefix) :]
        return world_id, "", rest
    return "", "", name


def as_path(value: str, root: Path):
    if not value:
        return None
    text = str(value)
    path = Path(text.replace("/", "\\")) if ":" in text else root / text
    if path.exists():
        return path
    path = Path(text)
    if path.exists():
        return path
    return None


def telemetry_value(result, key, default=0):
    telemetry = result.get("worldViewerTelemetry") or {}
    value = telemetry.get(key)
    if value is None:
        return default
    return value


def collect_records(sweep_root: Path, root: Path):
    records = []
    for manifest in sweep_root.glob("*/*/manifest.json"):
        target_dir = manifest.parent.parent
        world_id, category_id, target_slug = parse_target_slug(target_dir)
        try:
            data = json.loads(manifest.read_text(encoding="ascii"))
        except Exception as exc:
            records.append(
                {
                    "worldId": world_id,
                    "categoryId": category_id,
                    "target": target_slug.replace("-", " "),
                    "status": "manifest-error",
                    "startCell": "",
                    "screenshot": "",
                    "manifest": str(manifest),
                    "qualityReasons": "",
                    "notes": str(exc),
                }
            )
            continue

        for result in data.get("results", []):
            shot = as_path(result.get("screenshot", ""), root)
            quality = result.get("screenshotQuality") or {}
            records.append(
                {
                    "worldId": result.get("worldId") or world_id,
                    "categoryId": category_id,
                    "target": target_slug.replace("-", " "),
                    "status": result.get("status", ""),
                    "startCell": result.get("startCell", ""),
                    "screenshot": str(shot) if shot else "",
                    "manifest": str(manifest),
                    "runDirectory": result.get("runDirectory", ""),
                    "cellActors": telemetry_value(result, "cellActors"),
                    "cellRenderedActors": telemetry_value(result, "cellRenderedActors"),
                    "actorRayActorHits": telemetry_value(result, "actorRayActorHits"),
                    "nativeActorPartsAttached": telemetry_value(result, "nativeActorPartsAttached"),
                    "nativeActorPartsRequested": telemetry_value(result, "nativeActorPartsRequested"),
                    "nativeActorPartsQuarantined": telemetry_value(result, "nativeActorPartsQuarantined"),
                    "bsGeometryQuarantines": telemetry_value(result, "bsGeometryQuarantineEvents"),
                    "proxyTposeRefs": telemetry_value(result, "proxyTposeRefs"),
                    "proxyAnimatedRefs": telemetry_value(result, "proxyAnimatedRefs"),
                    "groundRayHits": telemetry_value(result, "groundRayHits"),
                    "centerRenderHits": telemetry_value(result, "centerRenderHits"),
                    "qualityReasons": "; ".join(quality.get("reasons") or []) if isinstance(quality, dict) else "",
                    "notes": "; ".join(result.get("notes") or []),
                }
            )

    def sort_key(record):
        world_rank = WORLD_ORDER.index(record["worldId"]) if record["worldId"] in WORLD_ORDER else 99
        category_rank = CATEGORY_ORDER.index(record["categoryId"]) if record["categoryId"] in CATEGORY_ORDER else 99
        return (world_rank, category_rank, record["target"])

    return sorted(records, key=sort_key)


def load_fonts():
    try:
        return (
            ImageFont.truetype("arial.ttf", 24),
            ImageFont.truetype("arial.ttf", 13),
            ImageFont.truetype("arial.ttf", 11),
        )
    except Exception:
        fallback = ImageFont.load_default()
        return fallback, fallback, fallback


def fit_text(draw, text, max_width, font, max_lines=2):
    words = str(text).replace("_", " ").split()
    lines = []
    current = ""
    for word in words:
        trial = f"{current} {word}".strip()
        width = draw.textbbox((0, 0), trial, font=font)[2]
        if width <= max_width or not current:
            current = trial
            continue
        lines.append(current)
        current = word
        if len(lines) >= max_lines:
            break
    if current and len(lines) < max_lines:
        lines.append(current)
    original = " ".join(words)
    if len(lines) == max_lines and len(" ".join(lines)) < len(original):
        while lines[-1] and draw.textbbox((0, 0), f"{lines[-1]}...", font=font)[2] > max_width:
            lines[-1] = lines[-1][:-1]
        lines[-1] = f"{lines[-1]}..."
    return lines


def draw_placeholder(tile, status, font):
    draw = ImageDraw.Draw(tile)
    lines = fit_text(draw, status or "no image", tile.width - 24, font, 2)
    y = tile.height // 2 - len(lines) * 8
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font)
        draw.text(((tile.width - (bbox[2] - bbox[0])) // 2, y), line, fill=(210, 210, 210), font=font)
        y += 18


def draw_matrix(records, out_path: Path, title: str, columns: int):
    title_font, font, small_font = load_fonts()
    tile_w = 230
    tile_h = 160
    caption_h = 62
    padding = 12
    header_h = 72
    rows = (len(records) + columns - 1) // columns
    width = columns * tile_w + (columns + 1) * padding
    height = header_h + rows * (tile_h + caption_h) + (rows + 1) * padding
    canvas = Image.new("RGB", (width, height), (18, 18, 18))
    draw = ImageDraw.Draw(canvas)
    draw.text((padding, 12), title, fill=(238, 238, 238), font=title_font)
    draw.text(
        (padding, 43),
        "  ".join(f"{key}:{value}" for key, value in Counter(record["status"] for record in records).items()),
        fill=(180, 180, 180),
        font=font,
    )

    for index, record in enumerate(records):
        column = index % columns
        row = index // columns
        x = padding + column * (tile_w + padding)
        y = header_h + padding + row * (tile_h + caption_h + padding)
        color = STATUS_COLOR.get(record.get("status"), (80, 80, 80))
        screenshot = record.get("screenshot")
        tile = Image.new("RGB", (tile_w, tile_h), (31, 31, 31))
        if screenshot and Path(screenshot).exists():
            try:
                with Image.open(screenshot) as image:
                    image = image.convert("RGB")
                    image = ImageOps.contain(image, (tile_w, tile_h), Image.Resampling.LANCZOS)
                    tile = Image.new("RGB", (tile_w, tile_h), (8, 8, 8))
                    tile.paste(image, ((tile_w - image.width) // 2, (tile_h - image.height) // 2))
            except Exception:
                draw_placeholder(tile, "image error", font)
        else:
            draw_placeholder(tile, record.get("status", "no image"), font)

        canvas.paste(tile, (x, y))
        draw.rectangle((x, y, x + tile_w - 1, y + tile_h - 1), outline=color, width=3)
        draw.rectangle((x, y, x + tile_w, y + 18), fill=color)
        badge = f"{WORLD_SHORT.get(record['worldId'], record['worldId'])} / {record['categoryId']}"
        draw.text((x + 5, y + 2), badge[:34], fill=(255, 255, 255), font=small_font)
        caption_y = y + tile_h + 6
        for line in fit_text(draw, record.get("target", ""), tile_w - 4, font, 2):
            draw.text((x + 2, caption_y), line, fill=(232, 232, 232), font=font)
            caption_y += 16
        draw.text((x + 2, caption_y), str(record.get("status", ""))[:36], fill=color, font=small_font)
        caption_y += 14
        start_cell = str(record.get("startCell") or "")
        if start_cell:
            draw.text((x + 2, caption_y), start_cell[:38], fill=(150, 150, 150), font=small_font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out_path)


def write_summaries(records, summary_dir: Path):
    summary_dir.mkdir(parents=True, exist_ok=True)
    summary = {
        "generatedAt": datetime.now().isoformat(),
        "count": len(records),
        "byStatus": dict(Counter(record["status"] for record in records)),
        "byWorld": {
            world_id: dict(Counter(record["status"] for record in records if record["worldId"] == world_id))
            for world_id in WORLD_ORDER
        },
        "records": records,
    }
    (summary_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="ascii")
    fieldnames = [
        "worldId",
        "categoryId",
        "target",
        "status",
        "startCell",
        "cellActors",
        "cellRenderedActors",
        "actorRayActorHits",
        "nativeActorPartsAttached",
        "nativeActorPartsRequested",
        "nativeActorPartsQuarantined",
        "bsGeometryQuarantines",
        "proxyTposeRefs",
        "proxyAnimatedRefs",
        "groundRayHits",
        "centerRenderHits",
        "screenshot",
        "manifest",
        "qualityReasons",
        "notes",
    ]
    with (summary_dir / "summary.csv").open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for record in records:
            writer.writerow({key: record.get(key, "") for key in fieldnames})


def main():
    parser = argparse.ArgumentParser(description="Build all-world actor proof collages and local summaries.")
    parser.add_argument("--sweep-root", required=True, help="Timestamped proof/adventure-actor-proofs sweep directory.")
    parser.add_argument("--out-dir", default="proof/collages", help="Output directory for generated PNG collages.")
    parser.add_argument("--summary-dir", default="", help="Directory for summary.json and summary.csv.")
    parser.add_argument("--columns", type=int, default=7)
    args = parser.parse_args()

    root = repo_root()
    sweep_root = (root / args.sweep_root).resolve() if not Path(args.sweep_root).is_absolute() else Path(args.sweep_root)
    out_dir = (root / args.out_dir).resolve() if not Path(args.out_dir).is_absolute() else Path(args.out_dir)
    if args.summary_dir:
        summary_dir = (root / args.summary_dir).resolve() if not Path(args.summary_dir).is_absolute() else Path(args.summary_dir)
    else:
        summary_dir = root / "proof" / "sweeps" / sweep_root.name

    records = collect_records(sweep_root, root)
    if not records:
        raise SystemExit(f"No manifest records found under {sweep_root}")

    run_out = out_dir / sweep_root.name
    full_path = run_out / "all-worlds-people-full-matrix.png"
    accepted_path = run_out / "all-worlds-people-accepted-pixels.png"
    draw_matrix(records, full_path, "All Worlds / All People - full proof audit", args.columns)
    accepted = [record for record in records if record.get("status") == "screenshot" and record.get("screenshot")]
    draw_matrix(accepted, accepted_path, "All Worlds / All People - accepted pixels", args.columns)
    write_summaries(records, summary_dir)

    latest_full = out_dir / "all-worlds-people-full-matrix.png"
    latest_accepted = out_dir / "all-worlds-people-accepted-pixels.png"
    latest_full.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(full_path, latest_full)
    shutil.copyfile(accepted_path, latest_accepted)
    print(
        json.dumps(
            {
                "records": len(records),
                "accepted": len(accepted),
                "fullMatrix": str(full_path),
                "acceptedPixels": str(accepted_path),
                "summaryJson": str(summary_dir / "summary.json"),
                "summaryCsv": str(summary_dir / "summary.csv"),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
