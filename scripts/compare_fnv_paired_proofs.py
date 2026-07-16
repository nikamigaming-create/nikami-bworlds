#!/usr/bin/env python3
"""Compare indexed retail/OpenMW actor proofs without launching either game.

The shared manifest is the authority for pair identity.  Capture order and file
names are never used to guess a pairing.  Pixel metrics are emitted only when
the manifest explicitly declares matched camera and state; otherwise the tool
still reports telemetry, geometry, alpha, part, and silhouette evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import textwrap
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import numpy as np
from PIL import Image, ImageDraw, ImageFont


SCHEMA = "nikami-fnv-paired-proof-report/v1"
MANIFEST_SCHEMA = "nikami-fnv-paired-proof-manifest/v1"
INDEX_KEYS = ("rows", "captures", "screenshots", "actors")
DEFAULT_THRESHOLDS = {
    "silhouetteIouMinimum": 0.90,
    "silhouetteRecallMinimum": 0.95,
    "silhouettePrecisionMinimum": 0.95,
    "silhouetteCentroidDeltaPercentMaximum": 3.0,
    "partRecallMinimum": 0.90,
    "partIouMinimum": 0.85,
    "opaqueAlphaMinimum": 0.95,
    "partAlphaDeltaMaximum": 0.08,
    "pixelMaeMaximum": 12.0,
    "pixelRmseMaximum": 20.0,
    "meanLumaDeltaMaximum": 10.0,
    "headBlackPixelExcessPercentMaximum": 5.0,
    "headLumaRatioMinimum": 0.45,
    "faceOverlayLayerDeficitMaximum": 0.0,
    "skinRelationColorDeltaMaximum": 24.0,
}


class ContractError(RuntimeError):
    """Raised when evidence cannot be paired deterministically."""


@dataclass
class Capture:
    key: str
    row: dict[str, Any]
    owner: Path
    screenshot: Path | None
    actor_mask: Path | None
    part_masks: dict[str, Path]
    telemetry: dict[str, Any]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path, help="Shared pair manifest")
    parser.add_argument("--retail-dir", required=True, type=Path, help="Indexed retail evidence directory")
    parser.add_argument("--openmw-dir", required=True, type=Path, help="Indexed OpenMW evidence directory")
    parser.add_argument("--retail-index", type=Path, help="Retail index; defaults to the only index in retail-dir")
    parser.add_argument("--openmw-index", type=Path, help="OpenMW index; defaults to the only index in openmw-dir")
    parser.add_argument("--output", required=True, type=Path, help="Output artifact directory")
    parser.add_argument("--rows-per-sheet", type=int, default=24, help="Rows per contact-sheet page")
    parser.add_argument("--thumbnail-width", type=int, default=300, help="Width of each image panel")
    parser.add_argument(
        "--fail-on-defect",
        action="store_true",
        help="Return 2 when any actor has a failure defect (artifacts are still written)",
    )
    return parser.parse_args(argv)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def read_json(path: Path, label: str) -> Any:
    require(path.is_file(), f"{label} does not exist: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"Unable to read {label} {path}: {exc}") from exc


def resolve_path(value: Any, owner: Path, *, must_exist: bool = False) -> Path | None:
    if isinstance(value, dict):
        value = value.get("path") or value.get("file")
    if not isinstance(value, str) or not value.strip():
        return None
    path = Path(value)
    if not path.is_absolute():
        path = owner.parent / path
    path = path.resolve()
    if must_exist and not path.is_file():
        raise ContractError(f"Referenced evidence does not exist: {path}")
    return path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_evidence(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {"present": False, "path": None}
    if not path.is_file():
        return {"present": False, "path": str(path), "missing": True}
    stat = path.stat()
    return {
        "present": True,
        "path": str(path),
        "bytes": stat.st_size,
        "sha256": sha256(path),
    }


def discover_index(directory: Path, explicit: Path | None, engine: str) -> Path:
    require(directory.is_dir(), f"{engine} evidence directory does not exist: {directory}")
    if explicit is not None:
        path = explicit if explicit.is_absolute() else directory / explicit
        path = path.resolve()
        require(path.is_file(), f"{engine} index does not exist: {path}")
        return path

    preferred = [directory / "index.json", directory / f"{engine}-index.json"]
    existing = [path.resolve() for path in preferred if path.is_file()]
    if len(existing) == 1:
        return existing[0]

    candidates = sorted(
        {
            path.resolve()
            for pattern in ("*index*.json", "manifest.json")
            for path in directory.glob(pattern)
            if path.is_file()
        },
        key=lambda item: os.path.normcase(str(item)),
    )
    require(candidates, f"No {engine} JSON index found directly in {directory}")
    require(
        len(candidates) == 1,
        f"Multiple {engine} indexes found; pass --{engine}-index explicitly: "
        + ", ".join(str(item) for item in candidates),
    )
    return candidates[0]


def capture_key(row: dict[str, Any], label: str) -> str:
    for key in ("captureId", "captureKey"):
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    target = row.get("targetId") or row.get("actorId") or row.get("editorId") or row.get("id")
    shot = row.get("shotKind") or row.get("poseState") or row.get("pose")
    require(
        isinstance(target, str) and target.strip() and isinstance(shot, str) and shot.strip(),
        f"{label} lacks captureId and deterministic target/shot identity",
    )
    return f"{target.strip()}::{shot.strip()}"


def rows_from_index(index: dict[str, Any], label: str) -> list[dict[str, Any]]:
    for key in INDEX_KEYS:
        rows = index.get(key)
        if isinstance(rows, list):
            require(all(isinstance(row, dict) for row in rows), f"{label}.{key} contains a non-object row")
            return rows
    require(False, f"{label} has none of the supported row arrays: {', '.join(INDEX_KEYS)}")
    return []


def load_optional_telemetry(value: Any, owner: Path) -> dict[str, Any]:
    if isinstance(value, dict) and not any(key in value for key in ("path", "file")):
        return value
    path = resolve_path(value, owner)
    if path is None or not path.is_file():
        return {}
    loaded = read_json(path, "capture telemetry")
    return loaded if isinstance(loaded, dict) else {"rows": loaded}


def path_mapping(value: Any, owner: Path) -> dict[str, Path]:
    if not isinstance(value, dict):
        return {}
    result: dict[str, Path] = {}
    for key, raw_path in value.items():
        path = resolve_path(raw_path, owner)
        if path is not None:
            result[str(key)] = path
    return result


def load_capture_index(path: Path, engine: str) -> dict[str, Capture]:
    raw = read_json(path, f"{engine} index")
    require(isinstance(raw, dict), f"{engine} index must contain a JSON object: {path}")
    captures: dict[str, Capture] = {}
    for ordinal, row in enumerate(rows_from_index(raw, f"{engine} index"), 1):
        key = capture_key(row, f"{engine} row {ordinal}")
        require(key not in captures, f"Duplicate {engine} capture key: {key}")
        screenshot = resolve_path(
            row.get("screenshot") or row.get("image") or row.get("screenshotPath") or row.get("path"), path
        )
        actor_mask = resolve_path(row.get("actorMask") or row.get("silhouetteMask") or row.get("mask"), path)
        telemetry = load_optional_telemetry(
            row.get("telemetry") or row.get("telemetryPath") or row.get("actorTelemetry"), path
        )
        part_masks = path_mapping(row.get("partMasks"), path)
        if not part_masks:
            part_masks = path_mapping(telemetry.get("partMasks"), path)
        captures[key] = Capture(key, row, path, screenshot, actor_mask, part_masks, telemetry)
    return captures


def actor_entries(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    rows = manifest.get("actors") or manifest.get("captures") or manifest.get("pairs")
    require(isinstance(rows, list) and rows, "Shared manifest must contain a non-empty actors/captures/pairs array")
    require(all(isinstance(row, dict) for row in rows), "Shared manifest pair array contains a non-object")
    return rows


def manifest_pair_key(entry: dict[str, Any], engine: str, ordinal: int) -> str:
    value = entry.get(f"{engine}CaptureId") or entry.get(f"{engine}Key") or entry.get("captureId")
    if isinstance(value, str) and value.strip():
        return value.strip()
    return capture_key(entry, f"manifest actor {ordinal}")


def normalized_parts(capture: Capture) -> dict[str, dict[str, Any]]:
    raw = capture.telemetry.get("parts")
    if raw is None:
        raw = capture.row.get("parts")
    result: dict[str, dict[str, Any]] = {}
    if isinstance(raw, dict):
        for key, value in raw.items():
            if isinstance(value, dict):
                result[str(key)] = value
            else:
                result[str(key)] = {"present": bool(value)}
    elif isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                result[item] = {"present": True}
            elif isinstance(item, dict):
                key = item.get("part") or item.get("name") or item.get("id")
                if key is not None:
                    result[str(key)] = item
    return result


def numeric(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def part_present(part: dict[str, Any] | None, mask: np.ndarray | None) -> bool | None:
    if mask is not None:
        return bool(mask.any())
    if not part:
        return None
    for key in ("rendered", "visible", "present", "attached", "geometryPresent"):
        if key in part:
            return bool(part[key])
    for key in ("vertexCount", "triangleCount", "drawableCount", "pixelCount"):
        if numeric(part.get(key)) is not None:
            return numeric(part.get(key)) > 0
    return None


def part_alpha(part: dict[str, Any] | None) -> float | None:
    if not part:
        return None
    for key in ("effectiveAlpha", "alpha", "materialAlpha", "opacity"):
        value = numeric(part.get(key))
        if value is not None:
            return value / 255.0 if value > 1.0 else value
    return None


def part_scalar(part: dict[str, Any] | None, keys: Iterable[str]) -> float | None:
    if not part:
        return None
    for key in keys:
        value = numeric(part.get(key))
        if value is not None:
            return value
    return None


def part_flag(part: dict[str, Any] | None, keys: Iterable[str]) -> bool | None:
    if not part:
        return None
    for key in keys:
        if key in part:
            return bool(part[key])
    return None


def part_rgb(part: dict[str, Any] | None) -> list[float] | None:
    if not part:
        return None
    for key in ("meanRgb", "meanColor", "materialRgb", "diffuseRgb", "color"):
        value = part.get(key)
        if isinstance(value, dict):
            value = [value.get(channel) for channel in ("r", "g", "b")]
        if isinstance(value, (list, tuple)) and len(value) >= 3:
            channels = [numeric(item) for item in value[:3]]
            if all(item is not None for item in channels):
                result = [float(item) for item in channels]
                if max(result) <= 1.0:
                    result = [item * 255.0 for item in result]
                return result
    return None


def appearance_summary(
    image: np.ndarray | None, mask: np.ndarray | None, part: dict[str, Any] | None
) -> dict[str, Any]:
    if image is not None and mask is not None and mask.any() and image.shape[:2] == mask.shape:
        pixels = image[:, :, :3][mask].astype(np.float64)
        pixel_luma = pixels[:, 0] * 0.2126 + pixels[:, 1] * 0.7152 + pixels[:, 2] * 0.0722
        return {
            "status": "measured",
            "source": "part-mask",
            "pixelCount": int(pixels.shape[0]),
            "meanRgb": [round(float(item), 6) for item in pixels.mean(axis=0)],
            "meanLuma": round(float(pixel_luma.mean()), 6),
            "blackPixelPercent": round(float((pixel_luma <= 16.0).mean() * 100.0), 6),
        }
    rgb = part_rgb(part)
    mean_luma = part_scalar(part, ("meanLuma", "luma"))
    black = part_scalar(part, ("blackPixelPercent", "nearBlackPixelPercent"))
    if rgb is not None and mean_luma is None:
        mean_luma = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
    if rgb is None and mean_luma is None and black is None:
        return {"status": "not-measured", "reason": "part mask/color telemetry unavailable"}
    return {
        "status": "measured",
        "source": "telemetry",
        "meanRgb": [round(item, 6) for item in rgb] if rgb is not None else None,
        "meanLuma": round(mean_luma, 6) if mean_luma is not None else None,
        "blackPixelPercent": round(black, 6) if black is not None else None,
    }


def normalized_slots(capture: Capture) -> dict[str, dict[str, Any]]:
    raw = (
        capture.telemetry.get("equipmentSlots")
        or capture.telemetry.get("slots")
        or capture.row.get("equipmentSlots")
        or capture.row.get("slots")
    )
    result: dict[str, dict[str, Any]] = {}
    if isinstance(raw, dict):
        for key, value in raw.items():
            result[str(key)] = value if isinstance(value, dict) else {"present": bool(value)}
    elif isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                result[item] = {"present": True}
            elif isinstance(item, dict):
                key = item.get("slot") or item.get("name") or item.get("id")
                if key is not None:
                    result[str(key)] = item
    return result


def slot_present(slot: dict[str, Any] | None) -> bool | None:
    if not slot:
        return None
    for key in ("visible", "rendered", "equipped", "present", "occupied"):
        if key in slot:
            return bool(slot[key])
    return None


def geometry_summary(capture: Capture, actor_mask: np.ndarray | None) -> dict[str, Any]:
    source = capture.telemetry.get("geometry") or capture.row.get("geometry") or {}
    if not isinstance(source, dict):
        source = {"present": bool(source)}
    present: bool | None = bool(actor_mask.any()) if actor_mask is not None else None
    if present is None:
        for key in ("present", "rendered", "visible", "attached"):
            if key in source:
                present = bool(source[key])
                break
    counts = {}
    for key in ("vertexCount", "triangleCount", "drawableCount", "nodeCount", "partCount"):
        value = numeric(source.get(key))
        if value is not None:
            counts[key] = int(value)
            if present is None:
                present = value > 0
    return {"status": "measured" if present is not None else "not-measured", "present": present, **counts}


def load_image(path: Path | None) -> np.ndarray | None:
    if path is None or not path.is_file():
        return None
    with Image.open(path) as source:
        return np.asarray(source.convert("RGBA"), dtype=np.uint8)


def load_mask(path: Path | None, expected_shape: tuple[int, int] | None = None) -> np.ndarray | None:
    if path is None or not path.is_file():
        return None
    with Image.open(path) as source:
        mask = np.asarray(source.convert("L"), dtype=np.uint8) > 0
    if expected_shape is not None:
        require(mask.shape == expected_shape, f"Mask shape {mask.shape} does not match screenshot {expected_shape}: {path}")
    return mask


def alpha_derived_mask(image: np.ndarray | None) -> np.ndarray | None:
    if image is None:
        return None
    alpha = image[:, :, 3]
    if np.all(alpha == 255):
        return None
    return alpha > 0


def alpha_stats(image: np.ndarray | None, mask: np.ndarray | None) -> dict[str, Any]:
    if image is None:
        return {"status": "not-measured", "reason": "screenshot missing"}
    alpha = image[:, :, 3]
    if np.all(alpha == 255):
        return {
            "status": "not-measured",
            "reason": "composited screenshot has no varying alpha; use telemetry or render-ID masks",
        }
    sample = alpha[mask] if mask is not None and mask.any() else alpha.reshape(-1)
    return {
        "status": "measured",
        "sampleCount": int(sample.size),
        "mean": round(float(sample.mean() / 255.0), 6),
        "zeroPercent": round(float((sample == 0).mean() * 100.0), 6),
        "partialPercent": round(float(((sample > 0) & (sample < 255)).mean() * 100.0), 6),
        "opaquePercent": round(float((sample == 255).mean() * 100.0), 6),
    }


def roi_bounds(value: Any, width: int, height: int) -> tuple[int, int, int, int]:
    if value is None:
        return (0, 0, width, height)
    if isinstance(value, dict):
        values = [value.get(key) for key in ("x", "y", "width", "height")]
    else:
        values = value
    require(isinstance(values, list) and len(values) == 4, "comparisonRoi must be [x,y,width,height] or an object")
    numbers = [numeric(item) for item in values]
    require(all(item is not None for item in numbers), "comparisonRoi contains a non-numeric value")
    x, y, w, h = (float(item) for item in numbers)
    if max(abs(x), abs(y), abs(w), abs(h)) <= 1.0:
        x, w = x * width, w * width
        y, h = y * height, h * height
    left = max(0, min(width, int(round(x))))
    top = max(0, min(height, int(round(y))))
    right = max(left, min(width, int(round(x + w))))
    bottom = max(top, min(height, int(round(y + h))))
    require(right > left and bottom > top, "comparisonRoi is empty after clipping")
    return left, top, right, bottom


def crop_array(array: np.ndarray | None, bounds: tuple[int, int, int, int]) -> np.ndarray | None:
    if array is None:
        return None
    left, top, right, bottom = bounds
    return array[top:bottom, left:right]


def bbox(mask: np.ndarray) -> dict[str, Any] | None:
    ys, xs = np.nonzero(mask)
    if xs.size == 0:
        return None
    return {
        "x": int(xs.min()),
        "y": int(ys.min()),
        "width": int(xs.max() - xs.min() + 1),
        "height": int(ys.max() - ys.min() + 1),
    }


def silhouette_metrics(retail: np.ndarray | None, openmw: np.ndarray | None) -> dict[str, Any]:
    if retail is None or openmw is None:
        return {
            "status": "not-measured",
            "reason": "both engines need actor masks (explicit mask or non-opaque screenshot alpha)",
        }
    if retail.shape != openmw.shape:
        return {
            "status": "not-measured",
            "reason": f"retail/OpenMW mask grids differ: {retail.shape} vs {openmw.shape}",
        }
    retail_count = int(retail.sum())
    openmw_count = int(openmw.sum())
    if retail_count == 0:
        return {"status": "not-measured", "reason": "retail reference mask is empty"}
    intersection = int(np.logical_and(retail, openmw).sum())
    union = int(np.logical_or(retail, openmw).sum())
    missing = int(np.logical_and(retail, ~openmw).sum())
    excess = int(np.logical_and(~retail, openmw).sum())
    ry, rx = np.nonzero(retail)
    oy, ox = np.nonzero(openmw)
    centroid_delta = None
    if ox.size:
        distance = math.hypot(float(rx.mean() - ox.mean()), float(ry.mean() - oy.mean()))
        centroid_delta = distance / math.hypot(*retail.shape) * 100.0
    return {
        "status": "measured",
        "pixelCount": int(retail.size),
        "retailArea": retail_count,
        "openmwArea": openmw_count,
        "intersection": intersection,
        "union": union,
        "iou": round(intersection / union if union else 1.0, 6),
        "recall": round(intersection / retail_count, 6),
        "precision": round(intersection / openmw_count if openmw_count else 0.0, 6),
        "missingRetailPixelsPercent": round(missing / retail_count * 100.0, 6),
        "excessOpenmwPixelsPercent": round(excess / retail_count * 100.0, 6),
        "areaRatioOpenmwToRetail": round(openmw_count / retail_count, 6),
        "centroidDeltaPercentOfDiagonal": round(centroid_delta, 6) if centroid_delta is not None else None,
        "retailBounds": bbox(retail),
        "openmwBounds": bbox(openmw),
    }


def luma(rgb: np.ndarray) -> np.ndarray:
    return rgb[:, :, 0] * 0.2126 + rgb[:, :, 1] * 0.7152 + rgb[:, :, 2] * 0.0722


def pixel_metrics(retail: np.ndarray, openmw: np.ndarray, mask: np.ndarray | None) -> dict[str, Any]:
    require(retail.shape == openmw.shape, f"Pixel grids differ: {retail.shape} vs {openmw.shape}")
    left = retail[:, :, :3].astype(np.float64)
    right = openmw[:, :, :3].astype(np.float64)
    selected = mask if mask is not None and mask.any() else np.ones(left.shape[:2], dtype=bool)
    left_pixels = left[selected]
    right_pixels = right[selected]
    absolute = np.abs(left_pixels - right_pixels)
    squared = (left_pixels - right_pixels) ** 2
    mae = float(absolute.mean())
    rmse = float(np.sqrt(squared.mean()))
    mse = float(squared.mean())
    left_luma = luma(left)[selected]
    right_luma = luma(right)[selected]
    mean_left = float(left_luma.mean())
    mean_right = float(right_luma.mean())
    c1 = (0.01 * 255) ** 2
    c2 = (0.03 * 255) ** 2
    covariance = float(np.mean((left_luma - mean_left) * (right_luma - mean_right)))
    variance_left = float(np.var(left_luma))
    variance_right = float(np.var(right_luma))
    ssim = ((2 * mean_left * mean_right + c1) * (2 * covariance + c2)) / (
        (mean_left**2 + mean_right**2 + c1) * (variance_left + variance_right + c2)
    )
    return {
        "status": "measured",
        "scope": "actor-mask-union" if mask is not None and mask.any() else "comparison-roi",
        "samplePixelCount": int(selected.sum()),
        "mae": round(mae, 6),
        "maeRgb": [round(float(value), 6) for value in absolute.mean(axis=0)],
        "rmse": round(rmse, 6),
        "p95AbsoluteError": round(float(np.percentile(absolute.mean(axis=1), 95)), 6),
        "psnr": None if mse <= 1e-12 else round(20.0 * math.log10(255.0 / math.sqrt(mse)), 6),
        "globalLumaSsim": round(float(ssim), 6),
        "retailMeanRgb": [round(float(value), 6) for value in left_pixels.mean(axis=0)],
        "openmwMeanRgb": [round(float(value), 6) for value in right_pixels.mean(axis=0)],
        "meanRgbDelta": [round(float(value), 6) for value in (right_pixels.mean(axis=0) - left_pixels.mean(axis=0))],
        "retailMeanLuma": round(mean_left, 6),
        "openmwMeanLuma": round(mean_right, 6),
        "meanLumaDelta": round(mean_right - mean_left, 6),
    }


def identity_value(capture: Capture, key: str) -> Any:
    value = capture.row.get(key)
    return capture.telemetry.get(key) if value is None else value


def add_defect(defects: list[dict[str, Any]], code: str, severity: str, message: str, **details: Any) -> None:
    defects.append({"code": code, "severity": severity, "message": message, **details})


def compare_identity(
    entry: dict[str, Any], retail: Capture, openmw: Capture, defects: list[dict[str, Any]]
) -> dict[str, Any]:
    fields = entry.get("identityFields") or [
        "actorId",
        "editorId",
        "formId",
        "baseFormId",
        "shotKind",
        "poseState",
        "cameraStateId",
        "weatherId",
        "gameTime",
        "weaponId",
    ]
    result: dict[str, Any] = {}
    for key in fields:
        expected = entry.get(key)
        left = identity_value(retail, key)
        right = identity_value(openmw, key)
        if expected is None and left is None and right is None:
            continue
        matches = (expected is None or (left == expected and right == expected)) and (
            left is None or right is None or left == right
        )
        result[key] = {"expected": expected, "retail": left, "openmw": right, "matches": matches}
        if not matches:
            add_defect(
                defects,
                "identity-state-mismatch",
                "failure",
                f"{key} differs across the declared pair",
                field=key,
                expected=expected,
                retail=left,
                openmw=right,
            )
    return result


def retail_authority_gate(
    entry: dict[str, Any],
    defaults: dict[str, Any],
    retail: Capture,
    defects: list[dict[str, Any]],
) -> dict[str, Any]:
    expected: dict[str, Any] = {}
    if isinstance(defaults.get("retailState"), dict):
        expected.update(defaults["retailState"])
    if isinstance(entry.get("retailState"), dict):
        expected.update(entry["retailState"])
    fields = entry.get(
        "retailAuthorityFields",
        defaults.get("retailAuthorityFields", ["cameraStateId", "poseState"]),
    )
    require(isinstance(fields, list), "retailAuthorityFields must be an array")
    result: dict[str, Any] = {}
    for key in dict.fromkeys([*fields, *expected.keys()]):
        actual = identity_value(retail, str(key))
        wanted = expected.get(key)
        status = "pass"
        if actual is None:
            status = "unknown"
            add_defect(
                defects,
                "retail-state-camera-unavailable",
                "unknown",
                f"Retail authority is missing required {key}",
                field=key,
            )
        elif key in expected and actual != wanted:
            status = "fail"
            add_defect(
                defects,
                "retail-authority-mismatch",
                "failure",
                f"Retail capture does not match manifest authority for {key}",
                field=key,
                expected=wanted,
                actual=actual,
            )
        result[str(key)] = {"expected": wanted, "retail": actual, "status": status}
    return {
        "status": "fail"
        if any(item["status"] == "fail" for item in result.values())
        else "unknown"
        if any(item["status"] == "unknown" for item in result.values())
        else "pass",
        "fields": result,
        "authority": "shared manifest defines expected retail state; retail telemetry must prove it",
    }


def resolve_named_part(
    candidates: Iterable[str],
    parts: dict[str, dict[str, Any]],
    masks: dict[str, np.ndarray],
) -> str | None:
    lookup = {key.casefold(): key for key in set(parts) | set(masks)}
    for candidate in candidates:
        found = lookup.get(str(candidate).casefold())
        if found is not None:
            return found
    return None


def compare_face_overlay(
    policy: dict[str, Any],
    retail_capture: Capture,
    openmw_capture: Capture,
    retail_image: np.ndarray | None,
    openmw_image: np.ndarray | None,
    retail_masks: dict[str, np.ndarray],
    openmw_masks: dict[str, np.ndarray],
    thresholds: dict[str, float],
    defects: list[dict[str, Any]],
) -> dict[str, Any]:
    retail_parts = normalized_parts(retail_capture)
    openmw_parts = normalized_parts(openmw_capture)
    candidates = policy.get("faceParts") or ["face", "head"]
    retail_name = resolve_named_part(candidates, retail_parts, retail_masks)
    openmw_name = resolve_named_part(candidates, openmw_parts, openmw_masks)
    retail_part = retail_parts.get(retail_name) if retail_name else None
    openmw_part = openmw_parts.get(openmw_name) if openmw_name else None
    retail_overlay = retail_capture.telemetry.get("faceOverlay")
    openmw_overlay = openmw_capture.telemetry.get("faceOverlay")
    if isinstance(retail_overlay, dict):
        retail_part = {**(retail_part or {}), **retail_overlay}
    if isinstance(openmw_overlay, dict):
        openmw_part = {**(openmw_part or {}), **openmw_overlay}
    retail_appearance = appearance_summary(retail_image, retail_masks.get(retail_name), retail_part)
    openmw_appearance = appearance_summary(openmw_image, openmw_masks.get(openmw_name), openmw_part)
    retail_overlay_applied = part_flag(
        retail_part,
        ("overlayApplied", "faceGenOverlayApplied", "faceOverlayApplied", "layersApplied"),
    )
    openmw_overlay_applied = part_flag(
        openmw_part,
        ("overlayApplied", "faceGenOverlayApplied", "faceOverlayApplied", "layersApplied"),
    )
    retail_layers = part_scalar(retail_part, ("overlayLayerCount", "layerCount", "textureStageCount"))
    openmw_layers = part_scalar(openmw_part, ("overlayLayerCount", "layerCount", "textureStageCount"))
    result = {
        "status": "measured"
        if retail_part is not None or openmw_part is not None or retail_appearance["status"] == "measured"
        else "not-measured",
        "retailPart": retail_name,
        "openmwPart": openmw_name,
        "retailAppearance": retail_appearance,
        "openmwAppearance": openmw_appearance,
        "retailOverlayApplied": retail_overlay_applied,
        "openmwOverlayApplied": openmw_overlay_applied,
        "retailLayerCount": retail_layers,
        "openmwLayerCount": openmw_layers,
    }
    if retail_overlay_applied is True and openmw_overlay_applied is False:
        add_defect(
            defects,
            "face-overlay-missing",
            "failure",
            "Retail face/head overlay is not applied in OpenMW",
        )
    elif policy.get("requireFaceOverlayEvidence") and (
        retail_overlay_applied is None or openmw_overlay_applied is None
    ):
        add_defect(
            defects,
            "face-overlay-evidence-unavailable",
            "unknown",
            "Face/head overlay application cannot be proven",
        )
    if retail_layers is not None and openmw_layers is not None:
        deficit = retail_layers - openmw_layers
        result["layerDeficit"] = deficit
        if deficit > thresholds["faceOverlayLayerDeficitMaximum"]:
            add_defect(
                defects,
                "face-overlay-layer-deficit",
                "failure",
                "OpenMW applies fewer face/head layers than retail",
                retailLayerCount=retail_layers,
                openmwLayerCount=openmw_layers,
            )
    retail_black = retail_appearance.get("blackPixelPercent")
    openmw_black = openmw_appearance.get("blackPixelPercent")
    if retail_black is not None and openmw_black is not None:
        black_excess = openmw_black - retail_black
        result["blackPixelExcessPercent"] = round(black_excess, 6)
        if black_excess > thresholds["headBlackPixelExcessPercentMaximum"]:
            add_defect(
                defects,
                "black-head-artifact",
                "failure",
                "OpenMW face/head has excess near-black coverage",
                retailBlackPixelPercent=retail_black,
                openmwBlackPixelPercent=openmw_black,
            )
    retail_luma = retail_appearance.get("meanLuma")
    openmw_luma = openmw_appearance.get("meanLuma")
    if retail_luma is not None and openmw_luma is not None and retail_luma > 1e-6:
        ratio = openmw_luma / retail_luma
        result["openmwToRetailLumaRatio"] = round(ratio, 6)
        if ratio < thresholds["headLumaRatioMinimum"]:
            add_defect(
                defects,
                "black-head-artifact",
                "failure",
                "OpenMW face/head luminance collapsed relative to retail",
                openmwToRetailLumaRatio=round(ratio, 6),
            )
    left_alpha = part_alpha(retail_part)
    right_alpha = part_alpha(openmw_part)
    if left_alpha is not None and right_alpha is not None and right_alpha + thresholds["partAlphaDeltaMaximum"] < left_alpha:
        add_defect(
            defects,
            "head-alpha-mismatch",
            "failure",
            "OpenMW face/head alpha is lower than retail",
            retailAlpha=left_alpha,
            openmwAlpha=right_alpha,
        )
    return result


def compare_skin_relations(
    policy: dict[str, Any],
    retail_capture: Capture,
    openmw_capture: Capture,
    retail_image: np.ndarray | None,
    openmw_image: np.ndarray | None,
    retail_masks: dict[str, np.ndarray],
    openmw_masks: dict[str, np.ndarray],
    thresholds: dict[str, float],
    defects: list[dict[str, Any]],
) -> dict[str, Any]:
    retail_parts = normalized_parts(retail_capture)
    openmw_parts = normalized_parts(openmw_capture)
    groups = policy.get("skinColorGroups") or [
        {"reference": ["face", "head"], "peers": [["leftHand"], ["rightHand"], ["bodySkin"]]}
    ]
    comparisons: list[dict[str, Any]] = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        reference_candidates = group.get("reference", ["face", "head"])
        if isinstance(reference_candidates, str):
            reference_candidates = [reference_candidates]
        peer_groups = group.get("peers", [])
        retail_reference_name = resolve_named_part(reference_candidates, retail_parts, retail_masks)
        openmw_reference_name = resolve_named_part(reference_candidates, openmw_parts, openmw_masks)
        retail_reference = appearance_summary(
            retail_image,
            retail_masks.get(retail_reference_name),
            retail_parts.get(retail_reference_name) if retail_reference_name else None,
        )
        openmw_reference = appearance_summary(
            openmw_image,
            openmw_masks.get(openmw_reference_name),
            openmw_parts.get(openmw_reference_name) if openmw_reference_name else None,
        )
        for peer_candidates in peer_groups:
            if isinstance(peer_candidates, str):
                peer_candidates = [peer_candidates]
            retail_peer_name = resolve_named_part(peer_candidates, retail_parts, retail_masks)
            openmw_peer_name = resolve_named_part(peer_candidates, openmw_parts, openmw_masks)
            retail_peer = appearance_summary(
                retail_image,
                retail_masks.get(retail_peer_name),
                retail_parts.get(retail_peer_name) if retail_peer_name else None,
            )
            openmw_peer = appearance_summary(
                openmw_image,
                openmw_masks.get(openmw_peer_name),
                openmw_parts.get(openmw_peer_name) if openmw_peer_name else None,
            )
            record = {
                "reference": {"retail": retail_reference_name, "openmw": openmw_reference_name},
                "peer": {"retail": retail_peer_name, "openmw": openmw_peer_name},
                "retailReference": retail_reference,
                "retailPeer": retail_peer,
                "openmwReference": openmw_reference,
                "openmwPeer": openmw_peer,
                "status": "not-measured",
            }
            colors = (
                retail_reference.get("meanRgb"),
                retail_peer.get("meanRgb"),
                openmw_reference.get("meanRgb"),
                openmw_peer.get("meanRgb"),
            )
            if all(color is not None for color in colors):
                rr, rp, ore, op = (np.asarray(color, dtype=np.float64) for color in colors)
                retail_relation = rp - rr
                openmw_relation = op - ore
                relation_delta = float(np.linalg.norm(openmw_relation - retail_relation))
                record.update(
                    {
                        "status": "measured",
                        "retailPeerMinusReferenceRgb": [round(float(item), 6) for item in retail_relation],
                        "openmwPeerMinusReferenceRgb": [round(float(item), 6) for item in openmw_relation],
                        "relationDelta": round(relation_delta, 6),
                    }
                )
                if relation_delta > thresholds["skinRelationColorDeltaMaximum"]:
                    add_defect(
                        defects,
                        "skin-part-color-mismatch",
                        "failure",
                        "Hand/body-skin color relationship to the face differs from retail",
                        reference=openmw_reference_name,
                        peer=openmw_peer_name,
                        relationDelta=round(relation_delta, 6),
                    )
            elif policy.get("requireSkinColorEvidence"):
                add_defect(
                    defects,
                    "skin-color-evidence-unavailable",
                    "unknown",
                    "Retail/OpenMW skin-region colors cannot be compared",
                    referenceCandidates=list(reference_candidates),
                    peerCandidates=list(peer_candidates),
                )
            comparisons.append(record)
    return {
        "status": "measured" if any(item["status"] == "measured" for item in comparisons) else "not-measured",
        "comparisons": comparisons,
        "note": "Relative region color reduces global exposure bias but still requires comparable lighting across body regions.",
    }


def compare_outfit_slots(
    policy: dict[str, Any],
    retail_capture: Capture,
    openmw_capture: Capture,
    defects: list[dict[str, Any]],
) -> dict[str, Any]:
    expected_raw = policy.get("expectedSlots")
    if expected_raw is None:
        return {"status": "not-measured", "reason": "manifest does not declare authoritative expectedSlots"}
    if isinstance(expected_raw, list):
        expected = {str(key): True for key in expected_raw}
    else:
        require(isinstance(expected_raw, dict), "expectedSlots must be an array or object")
        expected = {str(key): bool(value) for key, value in expected_raw.items()}
    retail_slots = normalized_slots(retail_capture)
    openmw_slots = normalized_slots(openmw_capture)
    rows: dict[str, Any] = {}
    proven = 0
    correct = 0
    for name, wanted in expected.items():
        retail_value = slot_present(retail_slots.get(name))
        openmw_value = slot_present(openmw_slots.get(name))
        status = "pass"
        if retail_value is None:
            status = "unknown"
            add_defect(
                defects,
                "retail-slot-evidence-unavailable",
                "unknown",
                f"Retail manifest expects slot {name}, but retail telemetry does not prove it",
                slot=name,
                expected=wanted,
            )
        elif retail_value != wanted:
            status = "fail"
            add_defect(
                defects,
                "retail-slot-authority-mismatch",
                "failure",
                f"Retail capture disagrees with manifest slot {name}",
                slot=name,
                expected=wanted,
                actual=retail_value,
            )
        if openmw_value is None:
            status = "unknown" if status == "pass" else status
            add_defect(
                defects,
                "openmw-slot-evidence-unavailable",
                "unknown",
                f"OpenMW telemetry does not prove slot {name}",
                slot=name,
                expected=wanted,
            )
        elif openmw_value != wanted:
            status = "fail"
            add_defect(
                defects,
                "outfit-slot-missing" if wanted else "outfit-slot-unexpected",
                "failure",
                f"OpenMW equipment slot {name} does not match retail authority",
                slot=name,
                expected=wanted,
                actual=openmw_value,
            )
        else:
            proven += 1
            if status == "pass":
                correct += 1
        rows[name] = {"expected": wanted, "retail": retail_value, "openmw": openmw_value, "status": status}
    return {
        "status": "fail"
        if any(item["status"] == "fail" for item in rows.values())
        else "unknown"
        if any(item["status"] == "unknown" for item in rows.values())
        else "pass",
        "expectedSlotCount": len(expected),
        "openmwProvenSlotCount": proven,
        "fullyCorrectSlotCount": correct,
        "coverage": round(correct / len(expected), 6) if expected else 1.0,
        "slots": rows,
    }


def compare_gore_caps(
    policy: dict[str, Any],
    retail_capture: Capture,
    openmw_capture: Capture,
    retail_masks: dict[str, np.ndarray],
    openmw_masks: dict[str, np.ndarray],
    defects: list[dict[str, Any]],
) -> dict[str, Any]:
    intact = policy.get("actorIntact")
    if intact is not True:
        return {
            "status": "not-applicable" if intact is False else "not-measured",
            "actorIntact": intact,
            "reason": "actorIntact must be explicitly true to gate hidden gore caps",
        }
    retail_parts = normalized_parts(retail_capture)
    openmw_parts = normalized_parts(openmw_capture)
    names = [str(item) for item in policy.get("goreCapParts", [])]
    for parts in (retail_parts, openmw_parts):
        for name, part in parts.items():
            role = str(part.get("role") or part.get("class") or part.get("kind") or "").casefold()
            if part.get("goreCap") is True or role in {"gore-cap", "gorecap", "dismemberment-cap"}:
                names.append(name)
    names = list(dict.fromkeys(names))
    if not names:
        if policy.get("requireGoreCapEvidence"):
            add_defect(
                defects,
                "gore-cap-evidence-unavailable",
                "unknown",
                "Intact actor has no declared or classified gore-cap telemetry",
            )
        return {"status": "not-measured", "actorIntact": True, "parts": {}}
    rows: dict[str, Any] = {}
    for name in names:
        retail_visible = part_present(retail_parts.get(name), retail_masks.get(name))
        openmw_visible = part_present(openmw_parts.get(name), openmw_masks.get(name))
        status = "pass"
        if retail_visible is True:
            status = "fail"
            add_defect(
                defects,
                "retail-intact-gore-cap-visible",
                "failure",
                f"Retail reference visibly exposes gore cap {name} on an intact actor",
                part=name,
            )
        elif retail_visible is None:
            status = "unknown"
            add_defect(
                defects,
                "retail-gore-cap-evidence-unavailable",
                "unknown",
                f"Retail does not prove gore cap {name} hidden",
                part=name,
            )
        if openmw_visible is True:
            status = "fail"
            add_defect(
                defects,
                "intact-gore-cap-visible",
                "failure",
                f"OpenMW visibly exposes gore cap {name} on an intact actor",
                part=name,
            )
        elif openmw_visible is None:
            status = "unknown" if status == "pass" else status
            add_defect(
                defects,
                "openmw-gore-cap-evidence-unavailable",
                "unknown",
                f"OpenMW does not prove gore cap {name} hidden",
                part=name,
            )
        rows[name] = {"retailVisible": retail_visible, "openmwVisible": openmw_visible, "status": status}
    return {
        "status": "fail"
        if any(item["status"] == "fail" for item in rows.values())
        else "unknown"
        if any(item["status"] == "unknown" for item in rows.values())
        else "pass",
        "actorIntact": True,
        "parts": rows,
    }


def compare_parts(
    expected: Iterable[str],
    retail_capture: Capture,
    openmw_capture: Capture,
    retail_masks: dict[str, np.ndarray],
    openmw_masks: dict[str, np.ndarray],
    thresholds: dict[str, float],
    defects: list[dict[str, Any]],
) -> dict[str, Any]:
    retail_parts = normalized_parts(retail_capture)
    openmw_parts = normalized_parts(openmw_capture)
    names = list(dict.fromkeys(str(item) for item in expected))
    result: dict[str, Any] = {}
    for name in names:
        left_part = retail_parts.get(name)
        right_part = openmw_parts.get(name)
        left_mask = retail_masks.get(name)
        right_mask = openmw_masks.get(name)
        left_present = part_present(left_part, left_mask)
        right_present = part_present(right_part, right_mask)
        left_alpha = part_alpha(left_part)
        right_alpha = part_alpha(right_part)
        coverage = silhouette_metrics(left_mask, right_mask)
        record = {
            "retailPresent": left_present,
            "openmwPresent": right_present,
            "retailAlpha": left_alpha,
            "openmwAlpha": right_alpha,
            "coverage": coverage,
        }
        if left_present is False:
            add_defect(
                defects,
                "retail-reference-part-missing",
                "failure",
                f"Retail reference lacks expected part {name}",
                part=name,
            )
        elif left_present is True and right_present is False:
            add_defect(defects, "part-missing", "failure", f"OpenMW lacks retail part {name}", part=name)
        elif left_present is None or right_present is None:
            add_defect(
                defects,
                "part-evidence-unavailable",
                "warning",
                f"Part presence cannot be proven for {name}",
                part=name,
            )
        if left_alpha is not None and right_alpha is not None:
            delta = right_alpha - left_alpha
            record["alphaDelta"] = round(delta, 6)
            if left_alpha >= thresholds["opaqueAlphaMinimum"] and right_alpha < thresholds["opaqueAlphaMinimum"]:
                add_defect(
                    defects,
                    "unexpected-part-transparency",
                    "failure",
                    f"OpenMW {name} is transparent while retail is opaque",
                    part=name,
                    retailAlpha=left_alpha,
                    openmwAlpha=right_alpha,
                )
            elif abs(delta) > thresholds["partAlphaDeltaMaximum"]:
                add_defect(
                    defects,
                    "part-alpha-mismatch",
                    "failure",
                    f"Alpha differs for {name}",
                    part=name,
                    retailAlpha=left_alpha,
                    openmwAlpha=right_alpha,
                )
        if coverage.get("status") == "measured":
            if coverage["recall"] < thresholds["partRecallMinimum"]:
                add_defect(
                    defects,
                    "part-coverage-missing",
                    "failure",
                    f"OpenMW covers too little of retail {name}",
                    part=name,
                    recall=coverage["recall"],
                )
            if coverage["iou"] < thresholds["partIouMinimum"]:
                add_defect(
                    defects,
                    "part-silhouette-mismatch",
                    "failure",
                    f"Part silhouette differs for {name}",
                    part=name,
                    iou=coverage["iou"],
                )
        result[name] = record
    return result


def highest_status(defects: list[dict[str, Any]]) -> str:
    if any(item["severity"] == "failure" for item in defects):
        return "fail"
    if any(item["severity"] == "unknown" for item in defects):
        return "unknown"
    if defects:
        return "warning"
    return "pass"


def compare_actor(
    entry: dict[str, Any],
    ordinal: int,
    retail_capture: Capture,
    openmw_capture: Capture,
    defaults: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    defects: list[dict[str, Any]] = []
    policy = dict(defaults)
    policy.update(entry)
    thresholds = dict(DEFAULT_THRESHOLDS)
    thresholds.update(defaults.get("thresholds") or {})
    thresholds.update(entry.get("thresholds") or {})
    thresholds = {key: float(value) for key, value in thresholds.items()}

    retail_image = load_image(retail_capture.screenshot)
    openmw_image = load_image(openmw_capture.screenshot)
    if retail_image is None:
        add_defect(defects, "retail-screenshot-missing", "failure", "Retail screenshot is missing")
    if openmw_image is None:
        add_defect(defects, "openmw-screenshot-missing", "failure", "OpenMW screenshot is missing")

    same_grid = retail_image is not None and openmw_image is not None and retail_image.shape == openmw_image.shape
    if retail_image is not None and openmw_image is not None and not same_grid:
        add_defect(
            defects,
            "pixel-grid-mismatch",
            "failure",
            "Retail and OpenMW screenshots have different dimensions",
            retail=list(retail_image.shape),
            openmw=list(openmw_image.shape),
        )

    if retail_capture.actor_mask is not None:
        retail_mask = load_mask(retail_capture.actor_mask, retail_image.shape[:2] if retail_image is not None else None)
    else:
        retail_mask = alpha_derived_mask(retail_image)
    if openmw_capture.actor_mask is not None:
        openmw_mask = load_mask(openmw_capture.actor_mask, openmw_image.shape[:2] if openmw_image is not None else None)
    else:
        openmw_mask = alpha_derived_mask(openmw_image)

    roi = entry.get("comparisonRoi", defaults.get("comparisonRoi"))
    retail_bounds = roi_bounds(roi, retail_image.shape[1], retail_image.shape[0]) if retail_image is not None else None
    openmw_bounds = roi_bounds(roi, openmw_image.shape[1], openmw_image.shape[0]) if openmw_image is not None else None
    retail_roi = crop_array(retail_image, retail_bounds) if retail_bounds else None
    openmw_roi = crop_array(openmw_image, openmw_bounds) if openmw_bounds else None
    retail_mask_roi = crop_array(retail_mask, retail_bounds) if retail_bounds else retail_mask
    openmw_mask_roi = crop_array(openmw_mask, openmw_bounds) if openmw_bounds else openmw_mask

    identity = compare_identity(entry, retail_capture, openmw_capture, defects)
    retail_authority = retail_authority_gate(entry, defaults, retail_capture, defects)
    retail_geometry = geometry_summary(retail_capture, retail_mask_roi)
    openmw_geometry = geometry_summary(openmw_capture, openmw_mask_roi)
    if retail_geometry["present"] is True and openmw_geometry["present"] is False:
        add_defect(defects, "geometry-missing", "failure", "OpenMW actor geometry is absent")
    if retail_geometry["status"] == "not-measured" or openmw_geometry["status"] == "not-measured":
        add_defect(
            defects,
            "geometry-evidence-unavailable",
            "warning",
            "Whole-actor geometry presence needs telemetry or an actor mask",
        )

    silhouette = silhouette_metrics(retail_mask_roi, openmw_mask_roi)
    if silhouette.get("status") == "measured":
        if silhouette["iou"] < thresholds["silhouetteIouMinimum"]:
            add_defect(
                defects,
                "silhouette-mismatch",
                "failure",
                "Whole-actor silhouettes differ",
                iou=silhouette["iou"],
            )
        if silhouette["recall"] < thresholds["silhouetteRecallMinimum"]:
            add_defect(
                defects,
                "silhouette-missing-coverage",
                "failure",
                "OpenMW is missing retail silhouette coverage",
                recall=silhouette["recall"],
            )
        if silhouette["precision"] < thresholds["silhouettePrecisionMinimum"]:
            add_defect(
                defects,
                "silhouette-excess-coverage",
                "failure",
                "OpenMW has silhouette coverage absent from retail",
                precision=silhouette["precision"],
            )
        delta = silhouette.get("centroidDeltaPercentOfDiagonal")
        if delta is not None and delta > thresholds["silhouetteCentroidDeltaPercentMaximum"]:
            add_defect(
                defects,
                "silhouette-offset",
                "failure",
                "Actor silhouette centroid is offset",
                centroidDeltaPercentOfDiagonal=delta,
            )
    else:
        add_defect(
            defects,
            "silhouette-evidence-unavailable",
            "warning",
            silhouette.get("reason", "Actor masks unavailable"),
        )

    retail_part_masks: dict[str, np.ndarray] = {}
    openmw_part_masks: dict[str, np.ndarray] = {}
    for name, path in retail_capture.part_masks.items():
        mask = load_mask(path, retail_image.shape[:2] if retail_image is not None else None)
        if mask is not None:
            retail_part_masks[name] = crop_array(mask, retail_bounds) if retail_bounds else mask
    for name, path in openmw_capture.part_masks.items():
        mask = load_mask(path, openmw_image.shape[:2] if openmw_image is not None else None)
        if mask is not None:
            openmw_part_masks[name] = crop_array(mask, openmw_bounds) if openmw_bounds else mask
    expected_parts = entry.get("expectedParts", defaults.get("expectedParts", []))
    parts = compare_parts(
        expected_parts,
        retail_capture,
        openmw_capture,
        retail_part_masks,
        openmw_part_masks,
        thresholds,
        defects,
    )
    face_overlay = compare_face_overlay(
        policy,
        retail_capture,
        openmw_capture,
        retail_roi,
        openmw_roi,
        retail_part_masks,
        openmw_part_masks,
        thresholds,
        defects,
    )
    skin_colors = compare_skin_relations(
        policy,
        retail_capture,
        openmw_capture,
        retail_roi,
        openmw_roi,
        retail_part_masks,
        openmw_part_masks,
        thresholds,
        defects,
    )
    outfit_slots = compare_outfit_slots(policy, retail_capture, openmw_capture, defects)
    gore_caps = compare_gore_caps(
        policy,
        retail_capture,
        openmw_capture,
        retail_part_masks,
        openmw_part_masks,
        defects,
    )

    matched = bool(entry.get("matchedCameraState", defaults.get("matchedCameraState", False)))
    if retail_authority["status"] != "pass":
        matched = False
    matched_fields = entry.get("matchedStateFields", defaults.get("matchedStateFields", []))
    missing_matched_fields = [
        key
        for key in matched_fields
        if identity_value(retail_capture, key) is None
        or identity_value(openmw_capture, key) is None
        or identity_value(retail_capture, key) != identity_value(openmw_capture, key)
    ]
    if missing_matched_fields:
        matched = False
        add_defect(
            defects,
            "matched-state-contract-failed",
            "failure",
            "Fields required by matchedStateFields are absent or unequal",
            fields=missing_matched_fields,
        )

    if matched and same_grid and retail_roi is not None and openmw_roi is not None:
        require(retail_roi.shape == openmw_roi.shape, "comparisonRoi produced unequal pixel grids")
        union_mask = None
        if retail_mask_roi is not None and openmw_mask_roi is not None:
            union_mask = np.logical_or(retail_mask_roi, openmw_mask_roi)
        pixels = pixel_metrics(retail_roi, openmw_roi, union_mask)
        if pixels["mae"] > thresholds["pixelMaeMaximum"]:
            add_defect(defects, "pixel-mae-high", "failure", "Aligned pixel MAE exceeds threshold", actual=pixels["mae"])
        if pixels["rmse"] > thresholds["pixelRmseMaximum"]:
            add_defect(
                defects, "pixel-rmse-high", "failure", "Aligned pixel RMSE exceeds threshold", actual=pixels["rmse"]
            )
        if abs(pixels["meanLumaDelta"]) > thresholds["meanLumaDeltaMaximum"]:
            add_defect(
                defects,
                "luma-mismatch",
                "failure",
                "Mean luminance differs across the aligned comparison",
                actual=pixels["meanLumaDelta"],
            )
    else:
        reasons = []
        if not matched:
            reasons.append("manifest does not prove matched camera/render state")
        if not same_grid:
            reasons.append("pixel grids differ or an image is missing")
        pixels = {"status": "not-measured", "reason": "; ".join(reasons)}
        add_defect(
            defects,
            "pixel-metrics-suppressed",
            "warning",
            "Aligned pixel metrics require matched camera, pose, animation frame, time/weather, and render state",
        )

    alpha = {
        "retail": alpha_stats(retail_roi, retail_mask_roi),
        "openmw": alpha_stats(openmw_roi, openmw_mask_roi),
        "note": "Composited RGB screenshots cannot prove material alpha; use per-part telemetry or render-ID/alpha masks.",
    }
    actor_id = str(entry.get("actorId") or entry.get("targetId") or entry.get("editorId") or entry.get("captureId"))
    result = {
        "ordinal": ordinal,
        "actorId": actor_id,
        "displayName": entry.get("displayName") or entry.get("name") or actor_id,
        "category": entry.get("category"),
        "retailCaptureId": retail_capture.key,
        "openmwCaptureId": openmw_capture.key,
        "status": highest_status(defects),
        "identity": identity,
        "retailAuthority": retail_authority,
        "requestedState": {
            "retail": retail_capture.row.get("requestedState"),
            "openmw": openmw_capture.row.get("requestedState"),
            "authority": "request metadata only; never treated as observed telemetry",
        },
        "evidence": {
            "retailScreenshot": file_evidence(retail_capture.screenshot),
            "openmwScreenshot": file_evidence(openmw_capture.screenshot),
            "retailActorMask": file_evidence(retail_capture.actor_mask),
            "openmwActorMask": file_evidence(openmw_capture.actor_mask),
        },
        "geometry": {"retail": retail_geometry, "openmw": openmw_geometry},
        "alpha": alpha,
        "silhouette": silhouette,
        "parts": parts,
        "faceOverlay": face_overlay,
        "skinColors": skin_colors,
        "outfitSlots": outfit_slots,
        "goreCaps": gore_caps,
        "pixels": pixels,
        "thresholds": thresholds,
        "defects": defects,
    }
    visual = {
        "actorId": actor_id,
        "displayName": result["displayName"],
        "status": result["status"],
        "defects": defects,
        "retail": retail_roi,
        "openmw": openmw_roi,
        "retailMask": retail_mask_roi,
        "openmwMask": openmw_mask_roi,
        "pixelMeasured": pixels.get("status") == "measured",
    }
    return result, visual


def fit_image(array: np.ndarray | None, width: int, height: int) -> Image.Image:
    canvas = Image.new("RGB", (width, height), (25, 27, 31))
    if array is None:
        draw = ImageDraw.Draw(canvas)
        draw.text((12, height // 2 - 8), "missing", fill=(235, 90, 90))
        return canvas
    source = Image.fromarray(array[:, :, :3].astype(np.uint8), mode="RGB")
    source.thumbnail((width, height), Image.Resampling.LANCZOS)
    canvas.paste(source, ((width - source.width) // 2, (height - source.height) // 2))
    return canvas


def delta_visual(retail: np.ndarray | None, openmw: np.ndarray | None, enabled: bool) -> np.ndarray | None:
    if not enabled or retail is None or openmw is None or retail.shape != openmw.shape:
        return None
    delta = np.abs(retail[:, :, :3].astype(np.int16) - openmw[:, :, :3].astype(np.int16))
    return np.clip(delta * 3, 0, 255).astype(np.uint8)


def mask_visual(retail: np.ndarray | None, openmw: np.ndarray | None) -> np.ndarray | None:
    if retail is None or openmw is None or retail.shape != openmw.shape:
        return None
    result = np.zeros((*retail.shape, 3), dtype=np.uint8)
    both = np.logical_and(retail, openmw)
    missing = np.logical_and(retail, ~openmw)
    excess = np.logical_and(~retail, openmw)
    result[both] = (225, 225, 225)
    result[missing] = (255, 70, 70)
    result[excess] = (50, 210, 255)
    return result


def contact_sheets(
    visuals: list[dict[str, Any]], output: Path, rows_per_sheet: int, panel_width: int
) -> list[Path]:
    rows_per_sheet = max(1, rows_per_sheet)
    panel_width = max(160, panel_width)
    panel_height = int(round(panel_width * 0.72))
    gap = 8
    header_height = 45
    label_height = 62
    columns = 4
    page_width = gap + columns * (panel_width + gap)
    row_height = panel_height + label_height + gap
    font = ImageFont.load_default()
    pages: list[Path] = []
    chunks = [visuals[index : index + rows_per_sheet] for index in range(0, len(visuals), rows_per_sheet)]
    for page_number, chunk in enumerate(chunks, 1):
        sheet = Image.new("RGB", (page_width, header_height + len(chunk) * row_height + gap), (15, 17, 20))
        draw = ImageDraw.Draw(sheet)
        draw.text(
            (gap, 8),
            "Retail | OpenMW | amplified absolute delta | silhouette (white=match red=missing cyan=excess)",
            fill=(235, 238, 242),
            font=font,
        )
        draw.text(
            (gap, 24),
            "Delta is blank when matched camera/state is not proven.",
            fill=(255, 200, 90),
            font=font,
        )
        for row_number, item in enumerate(chunk):
            y = header_height + row_number * row_height
            panels = [
                item["retail"],
                item["openmw"],
                delta_visual(item["retail"], item["openmw"], item["pixelMeasured"]),
                mask_visual(item["retailMask"], item["openmwMask"]),
            ]
            for column, array in enumerate(panels):
                x = gap + column * (panel_width + gap)
                sheet.paste(fit_image(array, panel_width, panel_height), (x, y))
            codes = [defect["code"] for defect in item["defects"]]
            label = f"{item['actorId']}  [{item['status'].upper()}]  {', '.join(codes) if codes else 'no defects'}"
            lines = textwrap.wrap(label, max(45, panel_width * columns // 8))[:3]
            color = (
                (245, 95, 95)
                if item["status"] == "fail"
                else (205, 155, 255)
                if item["status"] == "unknown"
                else (255, 205, 90)
                if item["status"] == "warning"
                else (120, 230, 145)
            )
            draw.multiline_text((gap, y + panel_height + 4), "\n".join(lines), fill=color, font=font, spacing=2)
        name = "contact-sheet.png" if len(chunks) == 1 else f"contact-sheet-{page_number:03d}.png"
        path = output / name
        sheet.save(path)
        pages.append(path)
    return pages


def run(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    manifest_path = args.manifest.resolve()
    retail_dir = args.retail_dir.resolve()
    openmw_dir = args.openmw_dir.resolve()
    output = args.output.resolve()
    manifest = read_json(manifest_path, "shared manifest")
    require(isinstance(manifest, dict), "Shared manifest must contain a JSON object")
    require(manifest.get("schema") == MANIFEST_SCHEMA, f"Unexpected manifest schema: {manifest.get('schema')!r}")
    retail_index_path = discover_index(retail_dir, args.retail_index, "retail")
    openmw_index_path = discover_index(openmw_dir, args.openmw_index, "openmw")
    retail_index = load_capture_index(retail_index_path, "retail")
    openmw_index = load_capture_index(openmw_index_path, "openmw")
    defaults = manifest.get("defaults") or {}
    require(isinstance(defaults, dict), "manifest.defaults must be an object")

    results: list[dict[str, Any]] = []
    visuals: list[dict[str, Any]] = []
    seen_retail: set[str] = set()
    seen_openmw: set[str] = set()
    for ordinal, entry in enumerate(actor_entries(manifest), 1):
        retail_key = manifest_pair_key(entry, "retail", ordinal)
        openmw_key = manifest_pair_key(entry, "openmw", ordinal)
        require(retail_key in retail_index, f"Manifest retail key is absent from retail index: {retail_key}")
        require(openmw_key in openmw_index, f"Manifest OpenMW key is absent from OpenMW index: {openmw_key}")
        require(retail_key not in seen_retail, f"Manifest reuses retail capture: {retail_key}")
        require(openmw_key not in seen_openmw, f"Manifest reuses OpenMW capture: {openmw_key}")
        seen_retail.add(retail_key)
        seen_openmw.add(openmw_key)
        result, visual = compare_actor(
            entry, ordinal, retail_index[retail_key], openmw_index[openmw_key], defaults
        )
        results.append(result)
        visuals.append(visual)

    output.mkdir(parents=True, exist_ok=True)
    page_paths = contact_sheets(visuals, output, args.rows_per_sheet, args.thumbnail_width)
    statuses = Counter(item["status"] for item in results)
    defect_codes = Counter(defect["code"] for item in results for defect in item["defects"])
    report_path = output / "paired-proof-report.json"
    defect_summary_path = output / "actor-defects.json"
    report = {
        "schema": SCHEMA,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "manifest": file_evidence(manifest_path),
        "inputs": {
            "retailDirectory": str(retail_dir),
            "openmwDirectory": str(openmw_dir),
            "retailIndex": file_evidence(retail_index_path),
            "openmwIndex": file_evidence(openmw_index_path),
        },
        "method": {
            "pairing": "shared-manifest capture keys; no filename/order inference",
            "registration": "none; no resizing, translation, warping, or color correction before metrics",
            "pixelMetricCaveat": (
                "Aligned pixel metrics are meaningful only for a genuinely matched camera matrix/FOV, actor transform, "
                "pose and animation frame, equipment, time/weather, lighting, post-processing, resolution, and crop. "
                "The comparator suppresses them unless matchedCameraState is explicitly true and any declared "
                "matchedStateFields agree."
            ),
            "alphaCaveat": (
                "A composited RGB screenshot does not preserve material alpha. Reliable alpha diagnosis requires "
                "per-part telemetry, render-ID masks, or uncomposited alpha-bearing captures."
            ),
        },
        "summary": {
            "actorCount": len(results),
            "pass": statuses["pass"],
            "warning": statuses["warning"],
            "unknown": statuses["unknown"],
            "fail": statuses["fail"],
            "pixelMetricsMeasured": sum(item["pixels"].get("status") == "measured" for item in results),
            "silhouettesMeasured": sum(item["silhouette"].get("status") == "measured" for item in results),
            "defectsByCode": dict(sorted(defect_codes.items())),
        },
        "actors": results,
        "artifacts": {
            "report": str(report_path),
            "actorDefects": str(defect_summary_path),
            "contactSheets": [str(path) for path in page_paths],
            "contactSheetIndex": str(output / "contact-sheet-index.json"),
        },
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    compact_defects = {
        "schema": "nikami-fnv-paired-proof-actor-defects/v1",
        "report": str(report_path),
        "summary": report["summary"],
        "actors": [
            {
                "actorId": item["actorId"],
                "displayName": item["displayName"],
                "status": item["status"],
                "retailCaptureId": item["retailCaptureId"],
                "openmwCaptureId": item["openmwCaptureId"],
                "defects": item["defects"],
                "silhouette": item["silhouette"],
                "pixels": item["pixels"],
                "faceOverlay": item["faceOverlay"],
                "skinColors": item["skinColors"],
                "outfitSlots": item["outfitSlots"],
                "goreCaps": item["goreCaps"],
            }
            for item in results
        ],
    }
    defect_summary_path.write_text(json.dumps(compact_defects, indent=2) + "\n", encoding="utf-8")
    sheet_index = {
        "schema": "nikami-fnv-paired-proof-contact-sheets/v1",
        "report": str(report_path),
        "actorCount": len(results),
        "rowsPerSheet": max(1, args.rows_per_sheet),
        "pages": [str(path) for path in page_paths],
    }
    (output / "contact-sheet-index.json").write_text(json.dumps(sheet_index, indent=2) + "\n", encoding="utf-8")
    exit_code = 2 if args.fail_on_defect and statuses["fail"] else 0
    return exit_code, report


def main(argv: list[str] | None = None) -> int:
    try:
        code, report = run(parse_args(argv))
    except ContractError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "schema": report["schema"],
                "actorCount": report["summary"]["actorCount"],
                "pass": report["summary"]["pass"],
                "warning": report["summary"]["warning"],
                "unknown": report["summary"]["unknown"],
                "fail": report["summary"]["fail"],
                "pixelMetricsMeasured": report["summary"]["pixelMetricsMeasured"],
                "report": report["artifacts"]["report"],
                "actorDefects": report["artifacts"]["actorDefects"],
                "contactSheets": report["artifacts"]["contactSheets"],
            },
            indent=2,
        )
    )
    return code


if __name__ == "__main__":
    raise SystemExit(main())
