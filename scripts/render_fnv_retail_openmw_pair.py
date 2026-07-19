#!/usr/bin/env python3
"""Render a hash-accounted Save330 retail frame beside an OpenMW screenshot.

The tool never launches either game and never grants visual acceptance.  A
right-hand frame can be labelled ``candidate`` only when a fail-closed capture
manifest proves that the exact image came from a committed flat OpenMW binary
which consumed Save330 through the normal load-game path, without diagnostic or
bootstrap state, and whose first-person camera/scene metadata matches the fixed
retail oracle.  Candidate images also fail immediately when they are monochrome,
one-colour, or effectively black.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import re
from pathlib import Path
from typing import Any

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat


SAVE330_BYTES = 3_395_328
SAVE330_SHA256 = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
SAVE330_SCREENSHOT_OFFSET = 147
SAVE330_SCREENSHOT_WIDTH = 512
SAVE330_SCREENSHOT_HEIGHT = 320
SAVE330_REFERENCE_PNG_SHA256 = "859fa4a89d0cc5efb16693a0aa104c264a1f9bc6c0bb257706b5401ceb8fd008"

PAIR_SCHEMA = "nikami-fnv-retail-openmw-visual-pair/v2"
CAPTURE_SCHEMA = "nikami-fnv-save330-openmw-capture/v1"
RETAIL_REFERENCE_SCHEMA = "nikami-fnv-save330-retail-visual-reference/v1"
OFFICIAL_CONTENT_ORDER = [
    "FalloutNV.esm",
    "DeadMoney.esm",
    "HonestHearts.esm",
    "OldWorldBlues.esm",
    "LonesomeRoad.esm",
    "GunRunnersArsenal.esm",
    "CaravanPack.esm",
    "ClassicPack.esm",
    "MercenaryPack.esm",
    "TribalPack.esm",
]
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
FORBIDDEN_ARGUMENT_PREFIXES = (
    "--start",
    "--new-game",
    "--script-run",
    "--startup-script",
    "positioncell",
    "teleport",
)
FORBIDDEN_ENVIRONMENT_PREFIXES = (
    "OPENMW_PROOF_",
    "OPENMW_WORLD_VIEWER_",
    "OPENMW_FNV_BOOTSTRAP",
    "OPENMW_STARTUP_SCRIPT",
)


class ProvenanceError(RuntimeError):
    """Raised when a frame cannot enter the Save330 candidate set."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProvenanceError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json_object(path: Path, label: str) -> dict[str, Any]:
    require(path.is_file(), f"{label} does not exist: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError(f"Unable to read {label} {path}: {exc}") from exc
    require(isinstance(value, dict), f"{label} must contain a JSON object")
    return value


def resolve_manifest_path(value: Any, owner: Path, label: str) -> Path:
    require(isinstance(value, str) and value.strip(), f"{label}.path is missing")
    path = Path(value)
    if not path.is_absolute():
        path = owner.parent / path
    return path.resolve()


def validate_file_evidence(
    value: Any,
    owner: Path,
    label: str,
    *,
    expected_path: Path | None = None,
    expected_bytes: int | None = None,
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be a file-evidence object")
    path = resolve_manifest_path(value.get("path"), owner, label)
    require(path.is_file(), f"{label} file does not exist: {path}")
    if expected_path is not None:
        require(path == expected_path.resolve(), f"{label} does not identify the supplied file")
    actual_bytes = path.stat().st_size
    declared_bytes = value.get("bytes")
    require(
        isinstance(declared_bytes, int) and not isinstance(declared_bytes, bool),
        f"{label}.bytes is missing",
    )
    require(declared_bytes == actual_bytes, f"{label}.bytes differs from the file on disk")
    declared_hash = str(value.get("sha256", "")).lower()
    require(bool(SHA256_RE.fullmatch(declared_hash)), f"{label}.sha256 is missing or malformed")
    actual_hash = sha256_file(path)
    require(declared_hash == actual_hash, f"{label}.sha256 differs from the file on disk")
    if expected_bytes is not None:
        require(actual_bytes == expected_bytes, f"{label} has {actual_bytes} bytes, expected {expected_bytes}")
    if expected_sha256 is not None:
        require(actual_hash == expected_sha256.lower(), f"{label} is not the pinned expected file")
    return {
        "path": str(path).replace("\\", "/"),
        "bytes": actual_bytes,
        "sha256": actual_hash,
    }


def finite_number(value: Any, label: str) -> float:
    require(not isinstance(value, bool), f"{label} must be numeric")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ProvenanceError(f"{label} must be numeric") from exc
    require(math.isfinite(result), f"{label} must be finite")
    return result


def vector3(value: Any, label: str) -> tuple[float, float, float]:
    if isinstance(value, dict):
        raw = [value.get("x"), value.get("y"), value.get("z")]
    else:
        require(isinstance(value, list) and len(value) == 3, f"{label} must contain x/y/z")
        raw = value
    return tuple(finite_number(component, f"{label}[{index}]") for index, component in enumerate(raw))


def normalized_crop(value: Any, label: str) -> tuple[float, float, float, float]:
    require(isinstance(value, list) and len(value) == 4, f"{label} must contain four normalized edges")
    crop = tuple(finite_number(component, f"{label}[{index}]") for index, component in enumerate(value))
    require(all(0.0 <= component <= 1.0 for component in crop), f"{label} edges must be within 0..1")
    require(crop[0] < crop[2] and crop[1] < crop[3], f"{label} has an empty rectangle")
    return crop


def optional_int_box(value: Any, label: str) -> list[int] | None:
    if value is None:
        return None
    require(isinstance(value, list) and len(value) == 4, f"{label} must be null or four integers")
    require(
        all(isinstance(component, int) and not isinstance(component, bool) for component in value),
        f"{label} must contain integers",
    )
    require(value[0] < value[2] and value[1] < value[3], f"{label} has an empty rectangle")
    return list(value)


def angular_delta(left: float, right: float) -> float:
    return abs((left - right + 180.0) % 360.0 - 180.0)


def time_delta_hours(left: float, right: float) -> float:
    return abs((left - right + 12.0) % 24.0 - 12.0)


def validate_candidate_provenance(
    provenance_path: Path,
    openmw_path: Path,
    source_size: tuple[int, int],
    *,
    openmw_crop: list[int] | None,
    fit_openmw: bool,
    comparison_crop: list[int] | None,
) -> dict[str, Any]:
    """Validate and summarize the complete right-hand candidate contract."""

    manifest_path = provenance_path.resolve()
    manifest = read_json_object(manifest_path, "OpenMW source-provenance manifest")
    require(manifest.get("schema") == CAPTURE_SCHEMA, f"OpenMW provenance schema must be {CAPTURE_SCHEMA}")
    require(manifest.get("status") == "passed", "OpenMW provenance status is not passed")
    require(manifest.get("candidateEligible") is True, "OpenMW provenance does not mark the capture candidate-eligible")

    launch = manifest.get("launch")
    require(isinstance(launch, dict), "OpenMW provenance.launch is missing")
    require(launch.get("engine") == "OpenMW", "Candidate launch engine must be OpenMW")
    require(launch.get("mode") == "flat", "Candidate launch must be flat, never VR")
    require(launch.get("kind") == "normal-save330-load", "Candidate launch kind is not normal-save330-load")
    require(launch.get("normalLoadGamePath") is True, "Candidate did not use the normal load-game path")
    for key in ("diagnostic", "bootstrap", "synthetic", "stateInjection"):
        require(launch.get(key) is False, f"Candidate launch.{key} must be false")
    injected_state = launch.get("injectedState")
    require(isinstance(injected_state, list) and not injected_state, "Candidate launch injected gameplay state")
    arguments = launch.get("arguments")
    require(isinstance(arguments, list) and all(isinstance(item, str) for item in arguments), "launch.arguments is invalid")
    for argument in arguments:
        normalized = argument.strip().lower()
        require(
            not any(normalized.startswith(prefix) for prefix in FORBIDDEN_ARGUMENT_PREFIXES),
            f"Candidate launch contains forbidden argument: {argument}",
        )
        require(normalized != "--no-sound", "Candidate launch is a no-sound diagnostic")
    environment = launch.get("environment")
    require(isinstance(environment, dict), "launch.environment must be an object")
    for name in environment:
        upper = str(name).upper()
        require(
            not any(upper.startswith(prefix) for prefix in FORBIDDEN_ENVIRONMENT_PREFIXES),
            f"Candidate launch contains forbidden proof/bootstrap environment: {name}",
        )

    save = validate_file_evidence(
        manifest.get("inputSave"),
        manifest_path,
        "inputSave",
        expected_bytes=SAVE330_BYTES,
        expected_sha256=SAVE330_SHA256,
    )
    input_save = manifest["inputSave"]
    require(input_save.get("consumedByRuntime") is True, "Save330 was not proven consumed by the runtime")
    require(input_save.get("normalLoadCompleted") is True, "Save330 normal load was not proven complete")
    require(
        str(input_save.get("loadedPlayerFormId", "")).lower() == "0x00000007",
        "Save330 did not restore native Player FormID 0x00000007",
    )

    runtime = manifest.get("runtime")
    require(isinstance(runtime, dict), "OpenMW provenance.runtime is missing")
    require(runtime.get("committedSource") is True, "Candidate runtime source is not committed")
    require(runtime.get("sourceDirty") is False, "Candidate runtime source tree was dirty")
    source_commit = str(runtime.get("sourceCommit", "")).lower()
    require(bool(COMMIT_RE.fullmatch(source_commit)), "Candidate runtime.sourceCommit is missing or malformed")
    binary = validate_file_evidence(runtime.get("binary"), manifest_path, "runtime.binary")
    require(Path(binary["path"]).name.lower() == "openmw.exe", "Candidate runtime is not flat openmw.exe")
    configuration = runtime.get("configuration")
    require(isinstance(configuration, list) and configuration, "Candidate runtime.configuration is empty")
    configuration_files = [
        validate_file_evidence(item, manifest_path, f"runtime.configuration[{index}]")
        for index, item in enumerate(configuration)
    ]
    require(runtime.get("contentOrder") == OFFICIAL_CONTENT_ORDER, "Candidate content order is not the frozen 10-master order")
    data_roots = runtime.get("dataRoots")
    require(isinstance(data_roots, list) and data_roots, "Candidate runtime.dataRoots is empty")
    resolved_data_roots: list[str] = []
    for index, value in enumerate(data_roots):
        path = resolve_manifest_path(value, manifest_path, f"runtime.dataRoots[{index}]")
        require(path.is_dir(), f"Candidate data root does not exist: {path}")
        resolved_data_roots.append(str(path).replace("\\", "/"))
    log = validate_file_evidence(runtime.get("log"), manifest_path, "runtime.log")

    capture = manifest.get("capture")
    require(isinstance(capture, dict), "OpenMW provenance.capture is missing")
    require(capture.get("kind") == "normal-gameplay-screenshot", "OpenMW frame is not a normal gameplay screenshot")
    require(capture.get("diagnostic") is False, "OpenMW frame is marked diagnostic")
    screenshot = validate_file_evidence(
        capture.get("screenshot"), manifest_path, "capture.screenshot", expected_path=openmw_path
    )
    screenshot_entry = capture["screenshot"]
    require(screenshot_entry.get("width") == source_size[0], "capture screenshot width differs from the image")
    require(screenshot_entry.get("height") == source_size[1], "capture screenshot height differs from the image")

    reference_evidence = validate_file_evidence(
        manifest.get("retailReferenceManifest"), manifest_path, "retailReferenceManifest"
    )
    reference_path = Path(reference_evidence["path"])
    reference = read_json_object(reference_path, "Save330 retail visual reference manifest")
    require(reference.get("schema") == RETAIL_REFERENCE_SCHEMA, "Retail reference manifest schema is unsupported")
    require(reference.get("status") == "fixed", "Retail reference manifest is not fixed")
    require(reference.get("saveSha256") == SAVE330_SHA256, "Retail reference does not identify exact Save330")
    reference_save = validate_file_evidence(
        reference.get("save"),
        reference_path,
        "retail reference save",
        expected_bytes=SAVE330_BYTES,
        expected_sha256=SAVE330_SHA256,
    )
    require(reference_save["sha256"] == save["sha256"], "Capture and retail oracle use different Save330 files")
    retail_image = reference.get("image")
    require(isinstance(retail_image, dict), "Retail reference image metadata is missing")
    validate_file_evidence(
        retail_image,
        reference_path,
        "retail reference image",
        expected_sha256=SAVE330_REFERENCE_PNG_SHA256,
    )
    require(retail_image.get("width") == SAVE330_SCREENSHOT_WIDTH, "Retail reference width is not pinned")
    require(retail_image.get("height") == SAVE330_SCREENSHOT_HEIGHT, "Retail reference height is not pinned")
    with Image.open(resolve_manifest_path(retail_image.get("path"), reference_path, "retail reference image")) as retail_source:
        require(
            retail_source.size == (SAVE330_SCREENSHOT_WIDTH, SAVE330_SCREENSHOT_HEIGHT),
            "Retail reference PNG dimensions differ from the pinned metadata",
        )
    reference_policy = reference.get("candidatePolicy")
    require(
        isinstance(reference_policy, dict) and reference_policy.get("eligibleNow") is True,
        "Retail reference candidate policy is not eligible",
    )

    retail_camera = reference.get("camera")
    retail_scene = reference.get("scene")
    openmw_camera = capture.get("camera")
    openmw_scene = capture.get("scene")
    require(isinstance(retail_camera, dict) and retail_camera.get("metadataStatus") == "complete", "Retail camera metadata is incomplete")
    require(isinstance(retail_scene, dict) and retail_scene.get("metadataStatus") == "complete", "Retail scene metadata is incomplete")
    require(isinstance(openmw_camera, dict), "OpenMW capture.camera is missing")
    require(isinstance(openmw_scene, dict), "OpenMW capture.scene is missing")
    require(retail_camera.get("mode") == "first-person", "Retail oracle camera is not first-person")
    require(openmw_camera.get("mode") == "first-person", "OpenMW candidate camera is not first-person")

    retail_position = vector3(retail_camera.get("position"), "retail camera.position")
    openmw_position = vector3(openmw_camera.get("position"), "OpenMW camera.position")
    retail_heading = finite_number(retail_camera.get("headingDegrees"), "retail camera.headingDegrees")
    openmw_heading = finite_number(openmw_camera.get("headingDegrees"), "OpenMW camera.headingDegrees")
    retail_fov = finite_number(retail_camera.get("fieldOfViewDegrees"), "retail camera.fieldOfViewDegrees")
    openmw_fov = finite_number(openmw_camera.get("fieldOfViewDegrees"), "OpenMW camera.fieldOfViewDegrees")
    require(1.0 <= retail_fov < 180.0 and 1.0 <= openmw_fov < 180.0, "Camera field of view is invalid")
    retail_viewport = normalized_crop(retail_camera.get("viewportCropNormalized"), "retail viewport crop")
    openmw_viewport = normalized_crop(openmw_camera.get("viewportCropNormalized"), "OpenMW viewport crop")

    retail_time = finite_number(retail_scene.get("gameTimeHours"), "retail scene.gameTimeHours")
    openmw_time = finite_number(openmw_scene.get("gameTimeHours"), "OpenMW scene.gameTimeHours")
    retail_weather = str(retail_scene.get("weatherFormId", "")).strip().lower()
    openmw_weather = str(openmw_scene.get("weatherFormId", "")).strip().lower()
    require(retail_weather and openmw_weather, "Retail/OpenMW weather FormID metadata is missing")
    retail_refs = retail_scene.get("visibleAuthoredReferences")
    openmw_refs = openmw_scene.get("visibleAuthoredReferences")
    require(isinstance(retail_refs, list) and retail_refs, "Retail visible-authored-reference set is empty")
    require(isinstance(openmw_refs, list) and openmw_refs, "OpenMW visible-authored-reference set is empty")
    require(all(isinstance(item, str) and item.strip() for item in retail_refs + openmw_refs), "Visible reference identity is invalid")

    tolerances = manifest.get("matchingTolerances")
    require(isinstance(tolerances, dict), "OpenMW provenance.matchingTolerances is missing")
    position_max = finite_number(tolerances.get("positionUnitsMaximum"), "positionUnitsMaximum")
    heading_max = finite_number(tolerances.get("headingDegreesMaximum"), "headingDegreesMaximum")
    fov_max = finite_number(tolerances.get("fieldOfViewDegreesMaximum"), "fieldOfViewDegreesMaximum")
    time_max = finite_number(tolerances.get("gameTimeHoursMaximum"), "gameTimeHoursMaximum")
    require(0.0 <= position_max <= 32.0, "Candidate position tolerance exceeds 32 world units")
    require(0.0 <= heading_max <= 2.0, "Candidate heading tolerance exceeds 2 degrees")
    require(0.0 <= fov_max <= 1.0, "Candidate FOV tolerance exceeds 1 degree")
    require(0.0 <= time_max <= 0.1, "Candidate game-time tolerance exceeds 0.1 hours")

    position_delta = math.dist(retail_position, openmw_position)
    heading_delta = angular_delta(retail_heading, openmw_heading)
    fov_delta = abs(retail_fov - openmw_fov)
    scene_time_delta = time_delta_hours(retail_time, openmw_time)
    crop_delta = max(abs(left - right) for left, right in zip(retail_viewport, openmw_viewport))
    require(position_delta <= position_max, "OpenMW camera position does not match the retail oracle")
    require(heading_delta <= heading_max, "OpenMW camera heading does not match the retail oracle")
    require(fov_delta <= fov_max, "OpenMW camera FOV does not match the retail oracle")
    require(crop_delta <= 0.001, "OpenMW camera crop does not match the retail oracle")
    require(scene_time_delta <= time_max, "OpenMW game time does not match the retail oracle")
    require(openmw_weather == retail_weather, "OpenMW weather does not match the retail oracle")
    require(
        sorted(item.strip().lower() for item in openmw_refs)
        == sorted(item.strip().lower() for item in retail_refs),
        "OpenMW visible authored references do not match the retail oracle",
    )

    pairing = manifest.get("pairing")
    require(isinstance(pairing, dict), "OpenMW provenance.pairing is missing")
    declared_openmw_crop = optional_int_box(pairing.get("openmwCropPixels"), "pairing.openmwCropPixels")
    declared_comparison_crop = optional_int_box(
        pairing.get("comparisonCropPixels"), "pairing.comparisonCropPixels"
    )
    require(declared_openmw_crop == openmw_crop, "--openmw-crop differs from capture provenance")
    require(pairing.get("fitOpenmw") is fit_openmw, "--fit-openmw differs from capture provenance")
    require(declared_comparison_crop == comparison_crop, "--crop differs from capture provenance")

    return {
        "schema": "nikami-fnv-save330-candidate-validation/v1",
        "status": "passed",
        "sourceManifest": {
            "path": str(manifest_path).replace("\\", "/"),
            "bytes": manifest_path.stat().st_size,
            "sha256": sha256_file(manifest_path),
            "schema": CAPTURE_SCHEMA,
        },
        "normalSave330Load": True,
        "flatFirstPerson": True,
        "diagnosticOrBootstrap": False,
        "save": save,
        "runtime": {
            "sourceCommit": source_commit,
            "binary": binary,
            "configuration": configuration_files,
            "contentOrder": OFFICIAL_CONTENT_ORDER,
            "dataRoots": resolved_data_roots,
            "log": log,
        },
        "screenshot": screenshot,
        "retailReferenceManifest": reference_evidence,
        "cameraAndSceneMatch": {
            "positionDeltaUnits": round(position_delta, 6),
            "headingDeltaDegrees": round(heading_delta, 6),
            "fieldOfViewDeltaDegrees": round(fov_delta, 6),
            "viewportCropMaximumDelta": round(crop_delta, 6),
            "gameTimeDeltaHours": round(scene_time_delta, 6),
            "weatherFormId": retail_weather,
            "visibleAuthoredReferences": sorted(retail_refs, key=str.casefold),
        },
    }


def analyze_image_quality(image: Image.Image) -> dict[str, Any]:
    sample = image.convert("RGB").copy()
    sample.thumbnail((256, 256), Image.Resampling.BILINEAR)
    pixels = list(
        sample.get_flattened_data()
        if hasattr(sample, "get_flattened_data")
        else sample.getdata()
    )
    require(bool(pixels), "OpenMW screenshot contains no pixels")
    chroma = [max(pixel) - min(pixel) for pixel in pixels]
    luma = [(0.2126 * red) + (0.7152 * green) + (0.0722 * blue) for red, green, blue in pixels]
    mean_chroma = sum(chroma) / len(chroma)
    colored_fraction = sum(value >= 8 for value in chroma) / len(chroma)
    mean_luma = sum(luma) / len(luma)
    luma_variance = sum((value - mean_luma) ** 2 for value in luma) / len(luma)
    luma_stddev = math.sqrt(luma_variance)
    non_black_fraction = sum(value > 12 for value in luma) / len(luma)
    unique_color_count = len(set(pixels))
    scene_height = max(1, int(sample.height * 0.8))
    scene_pixels = [sample.getpixel((x, y)) for y in range(scene_height) for x in range(sample.width)]
    scene_chroma = [max(pixel) - min(pixel) for pixel in scene_pixels]
    scene_mean_chroma = sum(scene_chroma) / len(scene_chroma)
    scene_colored_fraction = sum(value >= 8 for value in scene_chroma) / len(scene_chroma)

    reasons: list[str] = []
    if (
        colored_fraction < 0.02
        or mean_chroma < 2.0
        or scene_colored_fraction < 0.02
        or scene_mean_chroma < 2.0
    ):
        reasons.append("monochrome-or-black-white")
    if unique_color_count < 16 or luma_stddev < 2.0:
        reasons.append("one-color-or-flat-frame")
    if non_black_fraction < 0.03 or mean_luma < 3.0:
        reasons.append("black-or-void-frame")
    return {
        "schema": "nikami-fnv-openmw-frame-quality/v1",
        "status": "passed" if not reasons else "rejected",
        "fullColor": not reasons,
        "sampleWidth": sample.width,
        "sampleHeight": sample.height,
        "meanChroma": round(mean_chroma, 6),
        "coloredPixelFraction": round(colored_fraction, 6),
        "sceneMeanChroma": round(scene_mean_chroma, 6),
        "sceneColoredPixelFraction": round(scene_colored_fraction, 6),
        "meanLuma": round(mean_luma, 6),
        "lumaStdDev": round(luma_stddev, 6),
        "nonBlackPixelFraction": round(non_black_fraction, 6),
        "uniqueColorCount": unique_color_count,
        "reasons": reasons,
    }


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
        help=f"OpenMW {CAPTURE_SCHEMA} manifest; mandatory for candidate status",
    )
    args = parser.parse_args()

    if args.status == "candidate":
        require(args.retail_save is not None, "Candidate pairs must use the pinned --retail-save Save330 oracle")
        require(args.width in (None, SAVE330_SCREENSHOT_WIDTH), "Candidate retail width must remain the pinned Save330 width")
        require(args.height in (None, SAVE330_SCREENSHOT_HEIGHT), "Candidate retail height must remain the pinned Save330 height")
        require(args.retail_save_offset == SAVE330_SCREENSHOT_OFFSET, "Candidate retail screenshot offset must remain pinned")
        require(args.manifest is not None, "Candidate pairs require --manifest output")
        require(args.source_provenance is not None and args.source_provenance.is_file(), "Candidate pairs require an existing --source-provenance manifest")
        require(args.label_height > 0 and args.left_label.strip() and args.right_label.strip(), "Candidate pairs must be visibly labelled")

    retail, retail_provenance = load_retail(args)
    if args.retail_output:
        args.retail_output.parent.mkdir(parents=True, exist_ok=True)
        retail.save(args.retail_output, format="PNG", optimize=False)
    with Image.open(args.openmw) as source:
        source_size = source.size
        openmw = source.convert("RGB")

    provenance_validation: dict[str, Any] | None = None
    provenance_rejection: str | None = None
    if args.source_provenance:
        try:
            provenance_validation = validate_candidate_provenance(
                args.source_provenance,
                args.openmw,
                source_size,
                openmw_crop=list(args.openmw_crop) if args.openmw_crop else None,
                fit_openmw=args.fit_openmw,
                comparison_crop=list(args.crop) if args.crop else None,
            )
        except ProvenanceError as exc:
            provenance_rejection = str(exc)
            if args.status == "candidate":
                raise

    if args.openmw_crop:
        if args.status == "candidate":
            left, top, right, bottom = args.openmw_crop
            require(
                0 <= left < right <= source_size[0] and 0 <= top < bottom <= source_size[1],
                "Candidate OpenMW crop crosses the source image bounds",
            )
            retained = ((right - left) * (bottom - top)) / (source_size[0] * source_size[1])
            require(retained >= 0.75, "Candidate OpenMW crop removes more than 25% of the supplied frame")
        openmw = openmw.crop(tuple(args.openmw_crop))
    quality = analyze_image_quality(openmw)
    if args.status == "candidate":
        require(quality["status"] == "passed", "Candidate OpenMW frame failed full-color image quality: " + ", ".join(quality["reasons"]))
        require(provenance_validation is not None, "Candidate OpenMW provenance did not validate")

    if args.fit_openmw and openmw.size != retail.size:
        if args.status == "candidate":
            retail_aspect = retail.width / retail.height
            openmw_aspect = openmw.width / openmw.height
            require(abs(retail_aspect - openmw_aspect) <= 0.001, "Candidate OpenMW crop aspect ratio differs from Save330")
        openmw = openmw.resize(retail.size, Image.Resampling.LANCZOS)
    if openmw.size != retail.size:
        raise RuntimeError(f"Image sizes differ: retail={retail.size}, OpenMW={openmw.size}")

    if args.crop:
        box = tuple(args.crop)
        if args.status == "candidate":
            left, top, right, bottom = box
            require(
                0 <= left < right <= retail.width and 0 <= top < bottom <= retail.height,
                "Candidate comparison crop crosses the paired image bounds",
            )
            retained = ((right - left) * (bottom - top)) / (retail.width * retail.height)
            require(retained >= 0.75, "Candidate comparison crop removes more than 25% of the scene")
        retail = retail.crop(box)
        openmw = openmw.crop(box)
        require(retail.width > 0 and retail.height > 0, "Comparison crop is empty")

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
                "bytes": args.source_provenance.stat().st_size,
                "sha256": sha256_file(args.source_provenance),
                "validation": provenance_validation,
                "rejection": provenance_rejection,
            }
        gate_reasons: list[str] = []
        if args.status != "candidate":
            gate_reasons.append(f"requested-status-is-{args.status}")
        if provenance_validation is None:
            gate_reasons.append(provenance_rejection or "normal-Save330 provenance is absent")
        if quality["status"] != "passed":
            gate_reasons.extend(quality["reasons"])
        candidate_eligible = args.status == "candidate" and not gate_reasons
        manifest = {
            "schema": PAIR_SCHEMA,
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "status": args.status,
            "accepted": False,
            "visualReviewRequired": True,
            "candidateGate": {
                "eligible": candidate_eligible,
                "normalSave330Provenance": provenance_validation is not None,
                "flatFirstPersonCameraAndSceneMatched": provenance_validation is not None,
                "fullColorFrame": quality["status"] == "passed",
                "diagnosticOrBootstrap": False if provenance_validation is not None else None,
                "reasons": gate_reasons,
            },
            "retail": retail_provenance,
            "openmw": {
                "path": str(args.openmw.resolve()).replace("\\", "/"),
                "bytes": args.openmw.stat().st_size,
                "sha256": sha256_file(args.openmw),
                "crop": args.openmw_crop,
                "fitToRetail": args.fit_openmw,
                "imageQuality": quality,
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
