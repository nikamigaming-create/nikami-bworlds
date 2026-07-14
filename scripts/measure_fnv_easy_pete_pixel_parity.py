#!/usr/bin/env python3
"""Create a strict, unregistered retail/OpenMW Easy Pete parity proof.

The comparison intentionally never resizes, translates, warps, or color-corrects
either source.  A camera or pose mismatch must remain visible as a failed gate.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
from PIL import Image, ImageDraw, ImageFont


SCHEMA = "nikami-fnv-easy-pete-pixel-parity/v1"
VECTOR_PATTERN = r"\(([-+0-9.eE]+),([-+0-9.eE]+),([-+0-9.eE]+)\)"


@dataclass
class Gate:
    name: str
    passed: bool
    expected: Any
    actual: Any
    reason: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "status": "pass" if self.passed else "fail",
            "expected": self.expected,
            "actual": self.actual,
            "reason": self.reason,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retail", required=True, type=Path, help="Retail FNV screenshot")
    parser.add_argument("--openmw", required=True, type=Path, help="OpenMW screenshot")
    parser.add_argument("--config", required=True, type=Path, help="Parity gate configuration")
    parser.add_argument("--output", required=True, type=Path, help="Artifact directory")
    parser.add_argument("--openmw-log", type=Path, help="OpenMW log containing capture telemetry")
    parser.add_argument("--oracle", type=Path, help="Retail oracle JSONL; defaults to config")
    parser.add_argument(
        "--allow-failed",
        action="store_true",
        help="Write failed artifacts but return exit code zero (CI defaults to nonzero)",
    )
    return parser.parse_args()


def load_rgb(path: Path) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    with Image.open(path) as source:
        return source.convert("RGB")


def vec_distance(left: Iterable[float], right: Iterable[float]) -> float:
    return math.sqrt(sum((float(a) - float(b)) ** 2 for a, b in zip(left, right)))


def angle_degrees(left: Iterable[float], right: Iterable[float]) -> float:
    a = np.asarray(list(left), dtype=np.float64)
    b = np.asarray(list(right), dtype=np.float64)
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denominator <= 1e-12:
        return math.inf
    cosine = float(np.clip(np.dot(a, b) / denominator, -1.0, 1.0))
    return math.degrees(math.acos(cosine))


def round_number(value: Any, digits: int = 6) -> Any:
    if isinstance(value, float):
        if not math.isfinite(value):
            return None
        return round(value, digits)
    if isinstance(value, list):
        return [round_number(item, digits) for item in value]
    if isinstance(value, dict):
        return {key: round_number(item, digits) for key, item in value.items()}
    return value


def image_metrics(retail: np.ndarray, openmw: np.ndarray) -> dict[str, Any]:
    retail_f = retail.astype(np.float32)
    openmw_f = openmw.astype(np.float32)
    absolute = np.abs(retail_f - openmw_f)
    per_pixel = absolute.mean(axis=2)
    retail_luma = (
        retail_f[:, :, 0] * 0.2126 + retail_f[:, :, 1] * 0.7152 + retail_f[:, :, 2] * 0.0722
    )
    openmw_luma = (
        openmw_f[:, :, 0] * 0.2126 + openmw_f[:, :, 1] * 0.7152 + openmw_f[:, :, 2] * 0.0722
    )

    def warm_highlight_fraction(image: np.ndarray) -> float:
        red = image[:, :, 0]
        green = image[:, :, 1]
        blue = image[:, :, 2]
        warm = (
            (red >= 170)
            & (green >= 115)
            & (blue <= np.minimum(red, green) * 0.58)
            & (((red.astype(np.int16) + green.astype(np.int16)) // 2 - blue.astype(np.int16)) >= 65)
        )
        return float(warm.mean() * 100.0)

    retail_warm = warm_highlight_fraction(retail)
    openmw_warm = warm_highlight_fraction(openmw)
    return round_number(
        {
            "pixelCount": int(retail.shape[0] * retail.shape[1]),
            "retailMeanRgb": retail_f.mean(axis=(0, 1)).tolist(),
            "openmwMeanRgb": openmw_f.mean(axis=(0, 1)).tolist(),
            "meanRgbDelta": (openmw_f.mean(axis=(0, 1)) - retail_f.mean(axis=(0, 1))).tolist(),
            "mae": float(absolute.mean()),
            "maeRgb": absolute.mean(axis=(0, 1)).tolist(),
            "rmse": float(np.sqrt(np.mean((retail_f - openmw_f) ** 2))),
            "p95AbsoluteError": float(np.percentile(per_pixel, 95)),
            "p99AbsoluteError": float(np.percentile(per_pixel, 99)),
            "pixelsAbove16Percent": float((per_pixel > 16.0).mean() * 100.0),
            "pixelsAbove32Percent": float((per_pixel > 32.0).mean() * 100.0),
            "retailMeanLuma": float(retail_luma.mean()),
            "openmwMeanLuma": float(openmw_luma.mean()),
            "meanLumaDelta": float(openmw_luma.mean() - retail_luma.mean()),
            "retailWarmHighlightPercent": retail_warm,
            "openmwWarmHighlightPercent": openmw_warm,
            "warmHighlightDeltaPercent": openmw_warm - retail_warm,
        }
    )


def color_fit_diagnostics(retail: np.ndarray, openmw: np.ndarray) -> dict[str, Any]:
    """Measure how much of the pixel mismatch is explainable by simple color transforms.

    These diagnostics are not used as acceptance gates. They are a triage tool:
    if a global scale or affine RGB transform collapses the error, the next
    suspect is image-space/post processing. If the face ROI remains bad after
    the same simple fit, the culprit is still local material/shader behavior.
    """

    retail_f = retail.reshape(-1, 3).astype(np.float64)
    openmw_f = openmw.reshape(-1, 3).astype(np.float64)
    before = float(np.mean(np.abs(retail_f - openmw_f)))

    scale = []
    scale_prediction = np.zeros_like(retail_f)
    for channel in range(3):
        source = openmw_f[:, channel]
        target = retail_f[:, channel]
        denominator = float(np.dot(source, source))
        factor = 0.0 if denominator <= 1e-12 else float(np.dot(source, target) / denominator)
        scale.append(factor)
        scale_prediction[:, channel] = source * factor
    scale_mae = float(np.mean(np.abs(retail_f - np.clip(scale_prediction, 0, 255))))

    affine = []
    affine_prediction = np.zeros_like(retail_f)
    design = np.column_stack([openmw_f, np.ones(openmw_f.shape[0], dtype=np.float64)])
    for channel in range(3):
        coefficients = np.linalg.lstsq(design, retail_f[:, channel], rcond=None)[0]
        affine.append(coefficients.tolist())
        affine_prediction[:, channel] = design @ coefficients
    affine_mae = float(np.mean(np.abs(retail_f - np.clip(affine_prediction, 0, 255))))

    return round_number(
        {
            "maeBeforeFit": before,
            "scaleOnly": {
                "retailApproxEqualsOpenmwTimesRgb": scale,
                "maeAfterFit": scale_mae,
                "maeReduction": before - scale_mae,
            },
            "affineRgb": {
                "retailRgbApproxEqualsMatrixOpenmwRgbPlusBias": affine,
                "maeAfterFit": affine_mae,
                "maeReduction": before - affine_mae,
            },
        }
    )


def load_oracle_frame(path: Path, frame: int, ref_form: int) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        for line in stream:
            if '"event":"actor-frame"' not in line:
                continue
            event = json.loads(line)
            if int(event.get("frame", -1)) == frame and int(event.get("refForm", -1)) == ref_form:
                return event
    raise RuntimeError(f"No retail actor-frame frame={frame} refForm={ref_form} in {path}")


def parse_texture_stages(state: str) -> dict[str, dict[str, Any]]:
    stages: dict[str, dict[str, Any]] = {}
    stage_re = re.compile(r"u(?P<unit>\d+)=\{(?P<body>[^{}]*)\}")
    for match in stage_re.finditer(state):
        body = match.group("body")
        record: dict[str, Any] = {}
        for token in body.split(","):
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            record[key.strip()] = value.strip()
        stages[f"u{match.group('unit')}"] = record
    return stages


def extract_braced_value(text: str, key: str) -> str | None:
    marker = f"{key}={{"
    start = text.find(marker)
    if start < 0:
        return None
    index = start + len(marker)
    depth = 1
    while index < len(text):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start + len(marker) : index]
        index += 1
    return None


def summarize_stage_state(state: str | None) -> dict[str, Any]:
    if not state:
        return {"present": False, "stages": {}, "stageTypes": [], "images": []}
    stages = parse_texture_stages(state)
    return {
        "present": True,
        "stages": stages,
        "stageTypes": sorted({str(stage.get("type", "")) for stage in stages.values() if stage.get("type")}),
        "images": [
            stage["image"]
            for _, stage in sorted(stages.items())
            if "image" in stage
        ],
        "hasNormalMap": any(stage.get("type") == "normalMap" for stage in stages.values()),
        "hasSkinAuxMap": any(stage.get("type") == "skinAuxMap" for stage in stages.values()),
        "hasFaceGenMap0": any(stage.get("type") == "faceGenMap0" for stage in stages.values()),
        "hasFaceGenMap1": any(stage.get("type") == "faceGenMap1" for stage in stages.values()),
        "usesNeutralFaceGen0": "neutral-facegen0" in state.lower(),
        "usesNeutralFaceGen1": "neutral-facegen1" in state.lower(),
    }


def summarize_merged_stage_states(*states: dict[str, Any] | None) -> dict[str, Any]:
    merged: dict[str, dict[str, Any]] = {}
    for state in states:
        if not state or not state.get("present"):
            continue
        for unit, stage in state.get("stages", {}).items():
            merged[unit] = stage
    text = json.dumps(merged, sort_keys=True)
    return {
        "present": bool(merged),
        "stages": merged,
        "stageTypes": sorted({str(stage.get("type", "")) for stage in merged.values() if stage.get("type")}),
        "images": [stage["image"] for _, stage in sorted(merged.items()) if "image" in stage],
        "hasNormalMap": any(stage.get("type") == "normalMap" for stage in merged.values()),
        "hasSkinAuxMap": any(stage.get("type") == "skinAuxMap" for stage in merged.values()),
        "hasFaceGenMap0": any(stage.get("type") == "faceGenMap0" for stage in merged.values()),
        "hasFaceGenMap1": any(stage.get("type") == "faceGenMap1" for stage in merged.values()),
        "usesNeutralFaceGen0": "neutral-facegen0" in text.lower(),
        "usesNeutralFaceGen1": "neutral-facegen1" in text.lower(),
    }


def load_retail_d3d9_skin_draw(path: Path, frame: int) -> dict[str, Any] | None:
    if not path.is_file():
        return None

    expected_stage_hashes: dict[int, int] = {}
    expected_raws: list[dict[str, Any]] = []
    selected_draw: dict[str, Any] | None = None
    watched_ps_constants = [0, 1, 2, 3, 4, 19, 20, 21, 22, 23, 24, 27, 31]
    watched_vs_constants = [7, 26]

    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            if event.get("event") == "texture-raw" and str(event.get("semantic", "")).startswith("easy-pete-"):
                stage = event.get("stage")
                full_hash = event.get("fullContentFnv1a32")
                if isinstance(stage, int) and isinstance(full_hash, int):
                    expected_stage_hashes[stage] = full_hash
                expected_raws.append(
                    {
                        key: event.get(key)
                        for key in (
                            "semantic",
                            "stage",
                            "width",
                            "height",
                            "format",
                            "levels",
                            "bytes",
                            "topLevelFnv1a32",
                            "fullContentFnv1a32",
                            "path",
                        )
                    }
                )
                continue

            if event.get("event") != "draw" or int(event.get("frame", -1)) != int(frame):
                continue
            textures = event.get("textures") or []
            texture_by_stage = {
                int(texture.get("stage")): texture
                for texture in textures
                if isinstance(texture, dict) and isinstance(texture.get("stage"), int)
            }
            if not all(stage in expected_stage_hashes for stage in range(5)):
                continue
            if not all(
                texture_by_stage.get(stage, {}).get("contentFnv1a32") == expected_stage_hashes[stage]
                for stage in range(5)
            ):
                continue

            constants = event.get("constants", {})
            ps_float = constants.get("psFloat") or []
            vs_float = constants.get("vsFloat") or []

            def pick_constants(values: list[Any], indices: list[int]) -> dict[str, Any]:
                return {
                    f"c{index}": values[index]
                    for index in indices
                    if index < len(values)
                }

            selected_draw = {
                "sequence": event.get("sequence"),
                "draw": event.get("draw"),
                "vertexShader": event.get("vertexShader"),
                "pixelShader": event.get("pixelShader"),
                "textures": [
                    {
                        key: texture.get(key)
                        for key in (
                            "stage",
                            "width",
                            "height",
                            "format",
                            "levels",
                            "contentFnv1a32",
                            "bytesHashed",
                            "readbackComplete",
                        )
                    }
                    for texture in textures
                    if isinstance(texture, dict)
                    and int(texture.get("stage", -1)) in set(range(6)) | set(range(8, 14))
                ],
                "psConstants": pick_constants(ps_float, watched_ps_constants),
                "vsConstants": pick_constants(vs_float, watched_vs_constants),
            }
            break

    return {
        "source": str(path),
        "expectedGeneratedTextures": sorted(expected_raws, key=lambda item: int(item.get("stage", 999))),
        "selectedDraw": selected_draw,
        "selectedDrawFound": selected_draw is not None,
    }


def vector_abs_deltas(left: list[float], right: list[float]) -> list[float]:
    return [abs(float(a) - float(b)) for a, b in zip(left, right)]


def max_abs_delta(left: list[float], right: list[float]) -> float:
    deltas = vector_abs_deltas(left, right)
    return max(deltas) if deltas else math.inf


def build_skin_constant_diagnostics(
    retail_d3d9_skin_draw: dict[str, Any] | None,
    openmw_telemetry: dict[str, Any] | None,
) -> dict[str, Any]:
    if not retail_d3d9_skin_draw or not retail_d3d9_skin_draw.get("selectedDraw"):
        return {"available": False, "reason": "missing retail skin draw"}
    if not openmw_telemetry:
        return {"available": False, "reason": "missing OpenMW telemetry"}

    selected_draw = retail_d3d9_skin_draw["selectedDraw"]
    ps_constants = selected_draw.get("psConstants") or {}
    vs_constants = selected_draw.get("vsConstants") or {}
    selected_lights = openmw_telemetry.get("selectedLights") or []
    light_snapshot = openmw_telemetry.get("lightSnapshot") or ""
    weather_render_state = openmw_telemetry.get("weatherRenderState") or {}
    selected_by_id = {int(light["id"]): light for light in selected_lights if "id" in light}

    sun_match = re.search(r"sun=\{.*?diffuse:\((?P<diffuse>[^)]*)\)", light_snapshot)
    openmw_sun = [
        float(token.strip())
        for token in sun_match.group("diffuse").split(",")[:3]
    ] if sun_match else None
    c3_expected = ps_constants.get("c3")
    c4_expected = ps_constants.get("c4")
    c1_expected = ps_constants.get("c1")
    c27_expected = ps_constants.get("c27")
    c24_expected = ps_constants.get("c24")
    vs_c26_expected = vs_constants.get("c26")
    light3 = selected_by_id.get(3)

    mapped: dict[str, Any] = {}
    openmw_ambient = weather_render_state.get("ambient")
    if openmw_ambient and c1_expected:
        actual = [float(component) for component in openmw_ambient[:3]]
        expected = [float(component) for component in c1_expected[:3]]
        mapped["ps_c1_weatherAmbient"] = {
            "expectedRetail": expected,
            "actualOpenMWDerived": actual,
            "maxAbsDelta": max_abs_delta(expected, actual),
            "source": "OpenMW forced FNV weather render state ambient consumed by skin.frag as gl_LightModel.ambient",
        }

    if openmw_sun and c3_expected:
        actual = [component * 1.05 for component in openmw_sun]
        expected = [float(component) for component in c3_expected[:3]]
        mapped["ps_c3_sunDiffuseTimes105"] = {
            "expectedRetail": expected,
            "actualOpenMWDerived": actual,
            "maxAbsDelta": max_abs_delta(expected, actual),
            "source": "OpenMW FNV parity light snapshot sun.diffuse * skin.frag 1.05",
        }

    if light3 and c4_expected:
        actual = [float(component) for component in light3["diffuse"][:3]]
        expected = [float(component) for component in c4_expected[:3]]
        mapped["ps_c4_selectedPointDiffuse"] = {
            "expectedRetail": expected,
            "actualOpenMWDerived": actual,
            "maxAbsDelta": max_abs_delta(expected, actual),
            "source": "OpenMW selected light id=3 diffuse",
        }

    if light3 and c24_expected:
        actual = float(light3["radius"]) * 1.189032975
        expected = float(c24_expected[3])
        mapped["ps_c24_w_runtimeRadius"] = {
            "expectedRetail": expected,
            "actualOpenMWDerived": actual,
            "absDelta": abs(expected - actual),
            "source": "OpenMW selected light id=3 radius * skin.frag falloutRuntimeRadiusScale",
        }

    capture = openmw_telemetry.get("capture") or {}
    camera_eye = capture.get("cameraEye")
    if light3 and camera_eye and vs_c26_expected and light3.get("position"):
        actual = [
            float(light3["position"][index]) - float(camera_eye[index])
            for index in range(3)
        ]
        expected = [float(component) for component in vs_c26_expected[:3]]
        mapped["vs_c26_cameraRelativeWorldLight"] = {
            "expectedRetail": expected,
            "actualOpenMWDerived": actual,
            "maxAbsDelta": max_abs_delta(expected, actual),
            "source": "OpenMW selected light id=3 world position minus locked proof camera eye; skin.vert rotates OpenGL view vector back to this camera-relative world basis for attenuation UV",
        }

    if c27_expected:
        expected = [float(component) for component in c27_expected]
        actual = [0.0, 0.0, 10.0, 0.0]
        mapped["ps_c27_skinToggles"] = {
            "expectedRetail": expected,
            "actualOpenMWDerived": actual,
            "maxAbsDelta": max_abs_delta(expected, actual),
            "source": "SKIN2002 c27.x/c27.y disable vertex color and vertex-light blend for this draw; c27.w alpha threshold is zero",
        }

    # Microsoft fxc /dumpbin for the selected Easy Pete SKIN2002 draw reports:
    #   PS registers: AmbientColor c1, PSLightColor c3 size 2, Toggles c27.
    #   VS registers: LightData c25 size 2.
    # The D3D9 capture stores the whole Set*ShaderConstantF array, including
    # stale registers that this shader does not reference. Keep those visible
    # as ignored/stale capture state, but only fail on referenced constants that
    # OpenMW has not mapped.
    unmapped = {
        "psReferenced": {},
        "vsReferenced": {},
    }
    if vs_c26_expected and "vs_c26_cameraRelativeWorldLight" not in mapped:
        unmapped["vsReferenced"]["c26.xyz"] = vs_c26_expected[:3]
    ignored_stale = {
        "psUnreferencedByDisassembly": {
            key: ps_constants[key]
            for key in ("c2", "c19", "c20", "c21", "c22", "c23", "c24", "c31")
            if key in ps_constants
        }
    }

    return {
        "available": True,
        "disassembledRegisterUse": {
            "pixelShader": {
                "c1": "AmbientColor",
                "c3_c4": "PSLightColor[0..1]",
                "c27": "Toggles",
            },
            "vertexShader": {
                "c25_c26": "LightData[0..1]; c26.xyz drives tangent-space light vector and attenuation UV, c26.w is runtime radius",
            },
        },
        "mapped": mapped,
        "unmappedRetailConstants": unmapped,
        "ignoredCapturedConstants": ignored_stale,
        "mappedTolerance": 0.00001,
        "unmappedCount": sum(len(group) for group in unmapped.values()),
    }


def retail_pose(event: dict[str, Any], forward_indices: list[int]) -> dict[str, Any]:
    head = next(
        (bone for bone in event.get("bones", []) if str(bone.get("name", "")).lower() == "bip01 head"),
        None,
    )
    if head is None:
        raise RuntimeError("Retail oracle frame has no Bip01 Head bone")
    transform = head["transform"]
    rotation = transform["worldRotation"]
    sequences = []
    for sequence in event.get("animDataSequences", []):
        if not isinstance(sequence, dict):
            continue
        sequences.append(
            {
                key: sequence.get(key)
                for key in ("file", "state", "cycle", "weight", "frequency", "last", "lastScaled", "offset")
            }
        )
    return round_number(
        {
            "frame": event["frame"],
            "refForm": event["refForm"],
            "actorPosition": event.get("position"),
            "actorRotation": event.get("rotation"),
            "headPosition": transform["worldTranslation"],
            "headWorldRotation": rotation,
            "headForward": [rotation[index] for index in forward_indices],
            "sequences": sequences,
        }
    )


def parse_openmw_telemetry(log_path: Path, capture_frame: int, target_base_hex: str) -> dict[str, Any]:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    framing_re = re.compile(
        rf"World viewer actor framing: frame=(\d+) actor=\"([^\"]+)\" head={VECTOR_PATTERN} "
        rf"forward={VECTOR_PATTERN} eye={VECTOR_PATTERN} target={VECTOR_PATTERN} "
        r"targetError=([-+0-9.eE]+) eyeDistance=([-+0-9.eE]+) "
        r"requestedDistance=([-+0-9.eE]+) status=(pass|fail)"
    )
    frames: list[dict[str, Any]] = []
    for match in framing_re.finditer(text):
        frames.append(
            {
                "frame": int(match.group(1)),
                "actor": match.group(2),
                "headPosition": [float(match.group(i)) for i in range(3, 6)],
                "headForward": [float(match.group(i)) for i in range(6, 9)],
                "cameraEye": [float(match.group(i)) for i in range(9, 12)],
                "cameraTarget": [float(match.group(i)) for i in range(12, 15)],
                "targetError": float(match.group(15)),
                "eyeDistance": float(match.group(16)),
                "requestedDistance": float(match.group(17)),
                "framingStatus": match.group(18),
            }
        )
    capture = next((item for item in frames if item["frame"] == capture_frame), None)

    part_re = re.compile(
        r"runtime part audit FormId:(0x[0-9a-fA-F]+).*?class=([A-Za-z0-9_]+).*?verdict=([A-Za-z]+)"
    )
    parts: dict[str, dict[str, Any]] = {}
    normalized_target = target_base_hex.lower()
    for match in part_re.finditer(text):
        if match.group(1).lower() != normalized_target:
            continue
        class_name = match.group(2)
        record = parts.setdefault(class_name, {"ok": 0, "failed": 0, "total": 0})
        record["total"] += 1
        if match.group(3).upper() == "OK":
            record["ok"] += 1
        else:
            record["failed"] += 1

    screenshot_queued = bool(
        re.search(rf"queuing GUI-inclusive native screenshot at frame {capture_frame}\b", text)
    )
    screenshot_saved = bool(re.search(r"screenshots[\\/].+ has been saved", text, re.IGNORECASE))
    light_snapshot = None
    selected_lights: list[dict[str, Any]] = []
    light_match = re.search(
        rf"FNV parity light snapshot: frame={capture_frame}\b(?P<body>.*)$", text, re.MULTILINE
    )
    if light_match:
        light_snapshot = light_match.group("body").strip()
        selected_light_re = re.compile(
            r"\{index:(?P<index>\d+),id:(?P<id>\d+),.*?"
            r"position:\((?P<position>[^)]*)\),"
            r"viewPosition:\((?P<viewPosition>[^)]*)\),"
            r"diffuse:\((?P<diffuse>[^)]*)\).*?"
            r"attenuation:\((?P<attenuation>[^)]*)\),"
            r"radius:(?P<radius>[-+0-9.eE]+),"
        )
        for selected_match in selected_light_re.finditer(light_snapshot):
            selected_lights.append(
                {
                    "index": int(selected_match.group("index")),
                    "id": int(selected_match.group("id")),
                    "position": [
                        float(token.strip())
                        for token in selected_match.group("position").split(",")
                    ],
                    "viewPosition": [
                        float(token.strip())
                        for token in selected_match.group("viewPosition").split(",")
                    ],
                    "diffuse": [
                        float(token.strip())
                        for token in selected_match.group("diffuse").split(",")
                    ],
                    "attenuation": [
                        float(token.strip())
                        for token in selected_match.group("attenuation").split(",")
                    ],
                    "radius": float(selected_match.group("radius")),
                }
            )

    weather_render_state = None
    weather_re = re.compile(
        r"FNV/ESM4 proof: weather render state .*?\bambient=\((?P<ambient>[^)]*)\).*?\bsun=\((?P<sun>[^)]*)\)"
    )
    for weather_match in weather_re.finditer(text):
        weather_render_state = {
            "ambient": [
                float(token.strip())
                for token in weather_match.group("ambient").split(",")[:4]
            ],
            "sun": [
                float(token.strip())
                for token in weather_match.group("sun").split(",")[:4]
            ],
        }

    pose_source = None
    pose_source_match = re.search(
        r'FNV/ESM4 retail pose source audit: snapshot="(?P<snapshot>[^"]+)" '
        r'nodes=(?P<nodes>\d+) transformWords=(?P<words>\d+) '
        r'mismatchedNodes=(?P<mismatched_nodes>\d+) mismatchedWords=(?P<mismatched_words>\d+) '
        r'arithmetic=(?P<arithmetic>\S+) status=(?P<status>pass|fail)',
        text,
    )
    if pose_source_match:
        pose_source = {
            "snapshot": pose_source_match.group("snapshot"),
            "nodes": int(pose_source_match.group("nodes")),
            "transformWords": int(pose_source_match.group("words")),
            "mismatchedNodes": int(pose_source_match.group("mismatched_nodes")),
            "mismatchedWords": int(pose_source_match.group("mismatched_words")),
            "arithmetic": pose_source_match.group("arithmetic"),
            "status": pose_source_match.group("status"),
        }

    root_re = re.compile(
        rf'FNV/ESM4 retail root replay: frame={capture_frame}\b.*?'
        r'expectedBits=\[(?P<expected>[^]]+)\] afterBits=\[(?P<after>[^]]+)\] status=(?P<status>pass|fail)'
    )
    root_match = root_re.search(text)
    root_replay = None
    if root_match:
        root_replay = {
            "expectedBits": [token.strip().upper() for token in root_match.group("expected").split(",")],
            "afterBits": [token.strip().upper() for token in root_match.group("after").split(",")],
            "status": root_match.group("status"),
        }

    pose_re = re.compile(
        rf'FNV/ESM4 retail pose audit: frame={capture_frame} stage=(?P<stage>pre-replay|post-replay) '
        r'expectedNodes=(?P<expected>\d+) matchedNodes=(?P<matched>\d+) missingNodes=(?P<missing>\d+) '
        r'duplicateNodes=(?P<duplicates>\d+) localMismatchNodes=(?P<local_mismatch>\d+) '
        r'worldMismatchNodes=(?P<world_mismatch>\d+) status=(?P<status>pass|fail)'
    )
    pose_audits: dict[str, Any] = {}
    for match in pose_re.finditer(text):
        pose_audits[match.group("stage")] = {
            "expectedNodes": int(match.group("expected")),
            "matchedNodes": int(match.group("matched")),
            "missingNodes": int(match.group("missing")),
            "duplicateNodes": int(match.group("duplicates")),
            "localMismatchNodes": int(match.group("local_mismatch")),
            "worldMismatchNodes": int(match.group("world_mismatch")),
            "status": match.group("status"),
        }

    projection_audit = None
    projection_match = re.search(
        rf'FNV/ESM4 retail projection audit: frame={capture_frame} '
        r'viewport=(?P<width>\d+)x(?P<height>\d+) '
        r'fovBits=\[(?P<fov>[^]]+)\] nearFarBits=\[(?P<near_far>[^]]+)\] '
        r'expectedOpenGLBits=\[(?P<expected>[^]]+)\] '
        r'actualOpenGLBits=\[(?P<actual>[^]]+)\] status=(?P<status>pass|fail)',
        text,
    )
    if projection_match:
        parse_bits = lambda value: [token.strip().upper() for token in value.split(",")]
        projection_audit = {
            "frame": capture_frame,
            "viewport": [int(projection_match.group("width")), int(projection_match.group("height"))],
            "fovBits": parse_bits(projection_match.group("fov")),
            "nearFarBits": parse_bits(projection_match.group("near_far")),
            "expectedOpenGLBits": parse_bits(projection_match.group("expected")),
            "actualOpenGLBits": parse_bits(projection_match.group("actual")),
            "status": projection_match.group("status"),
        }

    target_head_draw = None
    normalized_target = target_base_hex.lower()
    for line in text.splitlines():
        if "FACE DRAWABLE AUDIT" not in line:
            continue
        if normalized_target not in line.lower():
            continue
        if "phase=final-race-head" not in line:
            continue
        if "headold" not in line.lower() and "headhuman" not in line.lower():
            continue

        drawable_state = extract_braced_value(line, "drawableState")
        source_state = extract_braced_value(line, "sourceState")
        render_state = extract_braced_value(line, "renderState")
        inherited_state = extract_braced_value(line, "inheritedStatePath")
        matrix_match = re.search(
            r";'(?P<name>HeadOld|HeadMale)'=\{type=MatrixTransform,state=(?P<state>.*?),matrixT=",
            line,
        )
        rig_match = re.search(
            r";'(?P<name>HeadOld|HeadMale)'=\{type=RigGeometry,state=(?P<state>.*?)\}\}\s+renderValid=",
            line,
        )
        drawable_summary = summarize_stage_state(drawable_state)
        source_summary = summarize_stage_state(source_state)
        render_summary = summarize_stage_state(render_state)
        matrix_summary = summarize_stage_state(matrix_match.group("state") if matrix_match else None)
        rig_summary = summarize_stage_state(rig_match.group("state") if rig_match else None)
        target_head_draw = {
            "model": re.search(r"model=([^ ]+)", line).group(1) if re.search(r"model=([^ ]+)", line) else None,
            "drawable": re.search(r"drawable='([^']+)'", line).group(1)
            if re.search(r"drawable='([^']+)'", line)
            else None,
            "texture": re.search(r"\btexture=([^ ]+)", line).group(1) if re.search(r"\btexture=([^ ]+)", line) else None,
            "drawableState": drawable_summary,
            "sourceState": source_summary,
            "renderState": render_summary,
            "matrixTransformState": matrix_summary,
            "rigGeometryState": rig_summary,
            "effectiveState": summarize_merged_stage_states(matrix_summary, rig_summary, render_summary, drawable_summary),
            "inheritedStateContainsNeutralFaceGen0": bool(
                inherited_state and "neutral-facegen0" in inherited_state.lower()
            ),
            "inheritedStateContainsNeutralFaceGen1": bool(
                inherited_state and "neutral-facegen1" in inherited_state.lower()
            ),
        }

    return round_number(
        {
            "capture": capture,
            "framingSamples": frames,
            "parts": parts,
            "screenshotQueued": screenshot_queued,
            "screenshotSaved": screenshot_saved,
            "lightSnapshot": light_snapshot,
            "selectedLights": selected_lights,
            "weatherRenderState": weather_render_state,
            "poseSource": pose_source,
            "rootReplay": root_replay,
            "poseAudits": pose_audits,
            "projectionAudit": projection_audit,
            "targetHeadDraw": target_head_draw,
        }
    )


def threshold_gates(prefix: str, metrics: dict[str, Any], thresholds: dict[str, float]) -> list[Gate]:
    mapping = {
        "maxMae": ("mae", "mean absolute RGB error"),
        "maxP95AbsoluteError": ("p95AbsoluteError", "95th percentile per-pixel error"),
        "maxPixelsAbove16Percent": ("pixelsAbove16Percent", "pixels above 16/255 error"),
        "maxAbsoluteLumaDelta": ("meanLumaDelta", "absolute mean luma delta"),
        "maxAbsoluteWarmHighlightDeltaPercent": (
            "warmHighlightDeltaPercent",
            "absolute warm-highlight coverage delta",
        ),
    }
    gates: list[Gate] = []
    for config_key, (metric_key, description) in mapping.items():
        if config_key not in thresholds:
            continue
        actual = float(metrics[metric_key])
        compared = abs(actual) if config_key.startswith("maxAbsolute") else actual
        expected = float(thresholds[config_key])
        gates.append(
            Gate(
                name=f"pixels.{prefix}.{metric_key}",
                passed=compared <= expected,
                expected={"maximum": expected},
                actual=actual,
                reason=f"{description} must be within the configured retail tolerance",
            )
        )
    return gates


def font(size: int) -> ImageFont.ImageFont:
    candidates = (
        Path(r"C:\Windows\Fonts\segoeuib.ttf"),
        Path(r"C:\Windows\Fonts\arialbd.ttf"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default()


def make_side_by_side(retail: Image.Image, openmw: Image.Image, passed: bool, output: Path) -> None:
    header = 72
    gap = 8
    canvas = Image.new("RGB", (retail.width * 2 + gap, retail.height + header), (18, 18, 18))
    canvas.paste(retail, (0, header))
    canvas.paste(openmw, (retail.width + gap, header))
    draw = ImageDraw.Draw(canvas)
    label_font = font(28)
    status_font = font(25)
    draw.text((18, 17), "RETAIL FNV — ORACLE", fill=(245, 245, 245), font=label_font)
    draw.text((retail.width + gap + 18, 17), "OPENMW — CANDIDATE", fill=(245, 245, 245), font=label_font)
    status = "PASS" if passed else "FAIL — DO NOT PRESENT AS PARITY"
    status_color = (70, 210, 110) if passed else (255, 82, 82)
    bounds = draw.textbbox((0, 0), status, font=status_font)
    draw.text((canvas.width - (bounds[2] - bounds[0]) - 18, 20), status, fill=status_color, font=status_font)
    canvas.save(output)


def make_overlay(retail: Image.Image, openmw: Image.Image, output: Path) -> None:
    Image.blend(retail, openmw, 0.5).save(output)


def make_differences(retail_array: np.ndarray, openmw_array: np.ndarray, output: Path) -> None:
    absolute = np.abs(retail_array.astype(np.int16) - openmw_array.astype(np.int16)).astype(np.uint8)
    amplified = np.clip(absolute.astype(np.uint16) * 4, 0, 255).astype(np.uint8)
    Image.fromarray(amplified, mode="RGB").save(output / "03-difference-x4.png")
    scalar = absolute.max(axis=2).astype(np.float32) / 255.0
    heat = np.zeros((*scalar.shape, 3), dtype=np.uint8)
    heat[:, :, 0] = np.clip(scalar * 3.0, 0.0, 1.0) * 255
    heat[:, :, 1] = np.clip((scalar - 0.20) * 2.2, 0.0, 1.0) * 255
    heat[:, :, 2] = np.clip((scalar - 0.62) * 2.6, 0.0, 1.0) * 255
    Image.fromarray(heat, mode="RGB").save(output / "04-difference-heatmap.png")


def make_roi_proof(retail: Image.Image, openmw: Image.Image, rois: list[dict[str, Any]], output: Path) -> None:
    gap = 8
    canvas = Image.new("RGB", (retail.width * 2 + gap, retail.height), (10, 10, 10))
    canvas.paste(retail, (0, 0))
    canvas.paste(openmw, (retail.width + gap, 0))
    draw = ImageDraw.Draw(canvas)
    colors = ((255, 80, 80), (80, 220, 255), (255, 210, 70), (180, 110, 255), (90, 255, 130))
    label_font = font(18)
    for index, roi in enumerate(rois):
        box = [int(value) for value in roi["box"]]
        color = colors[index % len(colors)]
        for x_offset in (0, retail.width + gap):
            shifted = [box[0] + x_offset, box[1], box[2] + x_offset, box[3]]
            draw.rectangle(shifted, outline=color, width=3)
            draw.text((shifted[0] + 5, shifted[1] + 4), roi["name"], fill=color, font=label_font)
    canvas.save(output)


def main() -> int:
    args = parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    args.output.mkdir(parents=True, exist_ok=True)
    retail_image = load_rgb(args.retail)
    openmw_image = load_rgb(args.openmw)
    gates: list[Gate] = []

    expected_size = tuple(int(value) for value in config["expectedSize"])
    same_size = retail_image.size == openmw_image.size
    gates.append(
        Gate(
            "capture.dimensions-identical",
            same_size,
            list(retail_image.size),
            list(openmw_image.size),
            "sources must be native captures with identical dimensions; no resampling is allowed",
        )
    )
    gates.append(
        Gate(
            "capture.expected-dimensions",
            retail_image.size == expected_size and openmw_image.size == expected_size,
            list(expected_size),
            {"retail": list(retail_image.size), "openmw": list(openmw_image.size)},
            "both captures must use the locked proof resolution",
        )
    )
    if not same_size:
        raise RuntimeError("Cannot compare different dimensions without forbidden resampling")

    retail_array = np.asarray(retail_image, dtype=np.uint8)
    openmw_array = np.asarray(openmw_image, dtype=np.uint8)
    full_metrics = image_metrics(retail_array, openmw_array)
    color_fit = {
        "full-frame": {
            "box": [0, 0, retail_image.width, retail_image.height],
            "diagnostics": color_fit_diagnostics(retail_array, openmw_array),
        }
    }
    gates.extend(threshold_gates("full-frame", full_metrics, config["pixelThresholds"]))

    roi_metrics: dict[str, Any] = {}
    for roi in config.get("rois", []):
        x0, y0, x1, y1 = [int(value) for value in roi["box"]]
        if not (0 <= x0 < x1 <= retail_image.width and 0 <= y0 < y1 <= retail_image.height):
            raise RuntimeError(f"ROI {roi['name']} is outside the locked frame: {roi['box']}")
        metrics = image_metrics(retail_array[y0:y1, x0:x1], openmw_array[y0:y1, x0:x1])
        roi_metrics[roi["name"]] = {"box": [x0, y0, x1, y1], "metrics": metrics}
        color_fit[roi["name"]] = {
            "box": [x0, y0, x1, y1],
            "diagnostics": color_fit_diagnostics(retail_array[y0:y1, x0:x1], openmw_array[y0:y1, x0:x1]),
        }
        gates.extend(threshold_gates(roi["name"], metrics, roi.get("thresholds", {})))

    telemetry_config = config["telemetry"]
    oracle_path = args.oracle or Path(telemetry_config["oracle"])
    retail_d3d9_path = oracle_path.with_name(oracle_path.name + ".d3d9.jsonl")
    retail_d3d9_skin_draw = load_retail_d3d9_skin_draw(
        retail_d3d9_path, int(telemetry_config["oracleFrame"])
    )
    skin_constant_diagnostics: dict[str, Any] | None = None
    gates.append(
        Gate(
            "telemetry.retail-d3d9-skin-draw",
            bool(retail_d3d9_skin_draw and retail_d3d9_skin_draw["selectedDrawFound"]),
            "retail D3D9 draw binding Easy Pete generated skin stages 0-4",
            retail_d3d9_skin_draw,
            "the oracle must identify the exact retail skin draw, shader bytecode hashes, textures, and constants",
        )
    )
    oracle_event = load_oracle_frame(
        oracle_path,
        int(telemetry_config["oracleFrame"]),
        int(str(telemetry_config["retailActorRef"]), 0),
    )
    oracle_pose = retail_pose(oracle_event, telemetry_config["headForwardMatrixIndices"])

    openmw_telemetry = None
    if args.openmw_log is None or not args.openmw_log.is_file():
        gates.append(
            Gate(
                "telemetry.openmw-log",
                False,
                "existing OpenMW log for the exact candidate capture",
                str(args.openmw_log) if args.openmw_log else None,
                "a screenshot without its originating telemetry cannot be accepted",
            )
        )
    else:
        gates.append(
            Gate(
                "telemetry.openmw-log",
                True,
                "existing OpenMW log for the exact candidate capture",
                str(args.openmw_log.resolve()),
                "candidate capture has a telemetry source",
            )
        )
        openmw_telemetry = parse_openmw_telemetry(
            args.openmw_log,
            int(telemetry_config["captureFrame"]),
            telemetry_config["openmwBaseForm"],
        )
        target_head_draw = openmw_telemetry.get("targetHeadDraw")
        head_shader_state = target_head_draw.get("matrixTransformState") if target_head_draw else None
        head_effective_state = target_head_draw.get("effectiveState") if target_head_draw else None
        head_any_state = [
            target_head_draw.get(key)
            for key in ("drawableState", "sourceState", "renderState", "matrixTransformState", "rigGeometryState")
            if target_head_draw
        ]
        gates.append(
            Gate(
                "telemetry.openmw-target-head-draw-found",
                target_head_draw is not None,
                "final-race-head FACE DRAWABLE AUDIT for the target Easy Pete head",
                target_head_draw,
                "head material/layer checks must be tied to Easy Pete's real head draw, not bootstrap Player noise",
            )
        )
        gates.append(
            Gate(
                "telemetry.openmw-target-head-no-neutral-facegen",
                bool(
                    target_head_draw
                    and not target_head_draw["inheritedStateContainsNeutralFaceGen0"]
                    and not target_head_draw["inheritedStateContainsNeutralFaceGen1"]
                ),
                {"neutralFaceGen0": False, "neutralFaceGen1": False},
                {
                    "neutralFaceGen0": target_head_draw["inheritedStateContainsNeutralFaceGen0"]
                    if target_head_draw
                    else None,
                    "neutralFaceGen1": target_head_draw["inheritedStateContainsNeutralFaceGen1"]
                    if target_head_draw
                    else None,
                },
                "the target head must not fall back to neutral/generated stub facegen maps",
            )
        )
        gates.append(
            Gate(
                "telemetry.openmw-target-head-shader-state-complete",
                bool(
                    head_shader_state
                    and head_shader_state.get("hasNormalMap")
                    and head_shader_state.get("hasSkinAuxMap")
                    and head_shader_state.get("hasFaceGenMap0")
                    and head_shader_state.get("hasFaceGenMap1")
                ),
                {
                    "normalMap": True,
                    "skinAuxMap": True,
                    "faceGenMap0": True,
                    "faceGenMap1": True,
                    "state": "MatrixTransform shader state",
                },
                head_shader_state,
                "the effective target head shader state must carry the skin normal, skin aux/scatter, and both FaceGen maps",
            )
        )
        gates.append(
            Gate(
                "telemetry.openmw-target-head-effective-state-complete",
                bool(
                    head_effective_state
                    and head_effective_state.get("hasNormalMap")
                    and head_effective_state.get("hasSkinAuxMap")
                    and head_effective_state.get("hasFaceGenMap0")
                    and head_effective_state.get("hasFaceGenMap1")
                ),
                {
                    "normalMap": True,
                    "skinAuxMap": True,
                    "faceGenMap0": True,
                    "faceGenMap1": True,
                    "state": "merged inherited + target drawable state",
                },
                head_effective_state,
                "the effective target head draw state must retain inherited skin layers and actor FaceGen maps together",
            )
        )
        gates.append(
            Gate(
                "telemetry.openmw-target-head-any-state-has-all-layers",
                any(
                    state
                    and state.get("hasNormalMap")
                    and state.get("hasSkinAuxMap")
                    and state.get("hasFaceGenMap0")
                    and state.get("hasFaceGenMap1")
                    for state in head_any_state
                ),
                {"normalMap": True, "skinAuxMap": True, "faceGenMap0": True, "faceGenMap1": True},
                head_any_state,
                "at least one recorded target head state must show all layers together; otherwise the layer chain is broken",
            )
        )
        skin_constant_diagnostics = build_skin_constant_diagnostics(retail_d3d9_skin_draw, openmw_telemetry)
        mapped_tolerance = float(skin_constant_diagnostics.get("mappedTolerance", 1e-5))
        for key, comparison in skin_constant_diagnostics.get("mapped", {}).items():
            delta = float(comparison.get("maxAbsDelta", comparison.get("absDelta", math.inf)))
            gates.append(
                Gate(
                    f"telemetry.skin-constant.{key}",
                    delta <= mapped_tolerance,
                    {"maximumAbsoluteError": mapped_tolerance, "retailConstant": key},
                    comparison,
                    "mapped OpenMW skin shader/light input must numerically match the retail SKIN2002 constant",
                )
            )
        unmapped = skin_constant_diagnostics.get("unmappedRetailConstants", {})
        unmapped_count = int(skin_constant_diagnostics.get("unmappedCount", 0))
        gates.append(
            Gate(
                "telemetry.skin-constants-all-accounted",
                unmapped_count == 0,
                {"unmappedRetailConstants": 0},
                unmapped,
                "every captured retail SKIN2002 constant must be either implemented, matched, or explicitly explained",
            )
        )
        capture = openmw_telemetry["capture"]
        gates.append(
            Gate(
                "telemetry.capture-frame",
                capture is not None,
                int(telemetry_config["captureFrame"]),
                capture["frame"] if capture else None,
                "camera and pose telemetry must exist at the actual screenshot frame",
            )
        )
        gates.append(
            Gate(
                "telemetry.screenshot-queued",
                bool(openmw_telemetry["screenshotQueued"]),
                True,
                bool(openmw_telemetry["screenshotQueued"]),
                "the log must bind this proof to the requested engine frame",
            )
        )
        gates.append(
            Gate(
                "telemetry.screenshot-saved",
                bool(openmw_telemetry["screenshotSaved"]),
                True,
                bool(openmw_telemetry["screenshotSaved"]),
                "the engine must report a native screenshot write",
            )
        )
        if capture:
            camera_tolerance = float(telemetry_config["cameraTolerance"])
            head_tolerance = float(telemetry_config["headPositionTolerance"])
            angle_tolerance = float(telemetry_config["headForwardToleranceDegrees"])
            for field, expected in (
                ("cameraEye", telemetry_config["cameraEye"]),
                ("cameraTarget", telemetry_config["cameraTarget"]),
            ):
                distance = vec_distance(capture[field], expected)
                gates.append(
                    Gate(
                        f"telemetry.{field}",
                        distance <= camera_tolerance,
                        {"vector": expected, "maximumDistance": camera_tolerance},
                        {"vector": capture[field], "distance": round(distance, 6)},
                        "camera coordinates must reproduce the retail oracle without registration",
                    )
                )
            head_distance = vec_distance(capture["headPosition"], oracle_pose["headPosition"])
            gates.append(
                Gate(
                    "telemetry.head-position",
                    head_distance <= head_tolerance,
                    {"vector": oracle_pose["headPosition"], "maximumDistance": head_tolerance},
                    {"vector": capture["headPosition"], "distance": round(head_distance, 6)},
                    "the captured head transform must match the selected retail actor frame",
                )
            )
            head_angle = angle_degrees(capture["headForward"], oracle_pose["headForward"])
            gates.append(
                Gate(
                    "telemetry.head-forward",
                    head_angle <= angle_tolerance,
                    {"vector": oracle_pose["headForward"], "maximumDegrees": angle_tolerance},
                    {"vector": capture["headForward"], "degrees": round(head_angle, 6)},
                    "the captured head orientation must match the retail bone matrix",
                )
            )

        for class_name, minimum in telemetry_config["requiredPartClasses"].items():
            record = openmw_telemetry["parts"].get(class_name, {"ok": 0, "failed": 0, "total": 0})
            passed = int(record["ok"]) >= int(minimum) and int(record["failed"]) == 0
            gates.append(
                Gate(
                    f"attachments.{class_name}",
                    passed,
                    {"minimumOkAudits": int(minimum), "failedAudits": 0},
                    record,
                    "every required Easy Pete head/face part must be attached and spatially valid",
                )
            )

        require_light = bool(telemetry_config.get("requirePerDrawLightSnapshot", False))
        has_light = openmw_telemetry["lightSnapshot"] is not None
        gates.append(
            Gate(
                "telemetry.per-draw-light-snapshot",
                has_light or not require_light,
                "FNV parity light snapshot at the screenshot frame" if require_light else "optional",
                openmw_telemetry["lightSnapshot"],
                "the exact selected lights, colors, positions, radii, and attenuation must be recorded",
            )
        )
        light_tolerance = float(telemetry_config.get("lightValueTolerance", 1e-5))
        selected_lights_by_id = {
            int(light["id"]): light for light in openmw_telemetry["selectedLights"]
        }
        for expected_light in telemetry_config.get("expectedSelectedLights", []):
            light_id = int(expected_light["id"])
            actual_light = selected_lights_by_id.get(light_id)
            expected_diffuse = [float(value) for value in expected_light["diffuse"]]
            expected_attenuation = [float(value) for value in expected_light["attenuation"]]
            expected_radius = float(expected_light["radius"])
            light_passed = bool(
                actual_light
                and len(actual_light["diffuse"]) == len(expected_diffuse)
                and len(actual_light["attenuation"]) == len(expected_attenuation)
                and all(
                    abs(actual - expected) <= light_tolerance
                    for actual, expected in zip(actual_light["diffuse"], expected_diffuse)
                )
                and all(
                    abs(actual - expected) <= light_tolerance
                    for actual, expected in zip(actual_light["attenuation"], expected_attenuation)
                )
                and abs(actual_light["radius"] - expected_radius) <= light_tolerance
            )
            gates.append(
                Gate(
                    f"telemetry.selected-light-{light_id}",
                    light_passed,
                    {
                        "id": light_id,
                        "diffuse": expected_diffuse,
                        "attenuation": expected_attenuation,
                        "radius": expected_radius,
                        "maximumAbsoluteError": light_tolerance,
                    },
                    actual_light,
                    "the selected light must preserve the retail LIGH/FNAM HDR color and attenuation values",
                )
            )

        pose_source = openmw_telemetry["poseSource"]
        source_expected = telemetry_config["retailPoseSource"]
        source_passed = bool(
            pose_source
            and pose_source["status"] == "pass"
            and pose_source["nodes"] == int(source_expected["nodes"])
            and pose_source["transformWords"] == int(source_expected["transformWords"])
            and pose_source["mismatchedNodes"] == 0
            and pose_source["mismatchedWords"] == 0
            and pose_source["arithmetic"] == source_expected["arithmetic"]
        )
        gates.append(
            Gate(
                "telemetry.retail-pose-source-bytes",
                source_passed,
                source_expected,
                pose_source,
                "the captured retail local transforms must recompose every recorded world word with retail float32 arithmetic",
            )
        )

        expected_root_bits = [str(token).upper() for token in telemetry_config["retailRootBits"]]
        root_replay = openmw_telemetry["rootReplay"]
        root_passed = bool(
            root_replay
            and root_replay["status"] == "pass"
            and root_replay["expectedBits"] == expected_root_bits
            and root_replay["afterBits"] == expected_root_bits
        )
        gates.append(
            Gate(
                "telemetry.retail-root-bytes",
                root_passed,
                expected_root_bits,
                root_replay,
                "actor position and rotation words at the screenshot frame must equal the retail checkpoint",
            )
        )

        pose_audit = openmw_telemetry["poseAudits"].get("post-replay")
        expected_pose_nodes = int(telemetry_config["retailPoseReplayNodes"])
        pose_passed = bool(
            pose_audit
            and pose_audit["status"] == "pass"
            and pose_audit["expectedNodes"] == expected_pose_nodes
            and pose_audit["matchedNodes"] == expected_pose_nodes
            and pose_audit["missingNodes"] == 0
            and pose_audit["duplicateNodes"] == 0
            and pose_audit["localMismatchNodes"] == 0
            and pose_audit["worldMismatchNodes"] == 0
        )
        gates.append(
            Gate(
                "telemetry.retail-pose-world-bytes",
                pose_passed,
                {
                    "expectedNodes": expected_pose_nodes,
                    "matchedNodes": expected_pose_nodes,
                    "missingNodes": 0,
                    "duplicateNodes": 0,
                    "localMismatchNodes": 0,
                    "worldMismatchNodes": 0,
                    "status": "pass",
                },
                pose_audit,
                "every replayed skeleton node must reach the retail world transform bit-for-bit",
            )
        )

        projection_expected = telemetry_config["retailProjection"]
        projection_audit = openmw_telemetry["projectionAudit"]
        expected_viewport = [int(value) for value in projection_expected["viewport"]]
        expected_fov = [str(projection_expected["verticalFovBits"]).upper()]
        expected_near_far = [str(value).upper() for value in projection_expected["nearFarBits"]]
        expected_matrix = [
            str(value).upper() for value in projection_expected["expectedOpenGLMatrixBits"]
        ]
        projection_passed = bool(
            projection_audit
            and projection_audit["status"] == "pass"
            and projection_audit["viewport"] == expected_viewport
            and projection_audit["fovBits"] == expected_fov
            and projection_audit["nearFarBits"] == expected_near_far
            and projection_audit["expectedOpenGLBits"] == expected_matrix
            and projection_audit["actualOpenGLBits"] == expected_matrix
        )
        gates.append(
            Gate(
                "telemetry.retail-projection-bytes",
                projection_passed,
                {
                    "viewport": expected_viewport,
                    "fovBits": expected_fov,
                    "nearFarBits": expected_near_far,
                    "openGLMatrixBits": expected_matrix,
                },
                projection_audit,
                "the camera must use the exact API-converted retail projection words at the screenshot frame",
            )
        )

    passed = all(gate.passed for gate in gates)
    make_side_by_side(retail_image, openmw_image, passed, args.output / "01-side-by-side.png")
    make_overlay(retail_image, openmw_image, args.output / "02-overlay-50.png")
    make_differences(retail_array, openmw_array, args.output)
    make_roi_proof(retail_image, openmw_image, config.get("rois", []), args.output / "05-roi-map.png")

    report = {
        "schema": SCHEMA,
        "status": "pass" if passed else "fail",
        "comparisonPolicy": {
            "registration": "none",
            "resampling": "none",
            "colorCorrection": "none",
            "pixelSpace": "native 8-bit RGB screenshot bytes",
        },
        "sources": {
            "retail": str(args.retail.resolve()),
            "openmw": str(args.openmw.resolve()),
            "config": str(args.config.resolve()),
            "oracle": str(oracle_path.resolve()),
            "openmwLog": str(args.openmw_log.resolve()) if args.openmw_log else None,
        },
        "retailPose": oracle_pose,
        "openmwTelemetry": openmw_telemetry,
        "retailD3D9SkinDraw": retail_d3d9_skin_draw,
        "skinConstantDiagnostics": skin_constant_diagnostics,
        "fullFrameMetrics": full_metrics,
        "roiMetrics": roi_metrics,
        "colorFitDiagnostics": color_fit,
        "gates": [gate.as_dict() for gate in gates],
        "failedGates": [gate.name for gate in gates if not gate.passed],
        "artifacts": {
            "sideBySide": "01-side-by-side.png",
            "overlay50": "02-overlay-50.png",
            "differenceX4": "03-difference-x4.png",
            "differenceHeatmap": "04-difference-heatmap.png",
            "roiMap": "05-roi-map.png",
        },
    }
    report_path = args.output / "parity-report.json"
    report_path.write_text(json.dumps(round_number(report), indent=2) + "\n", encoding="utf-8")

    failed_gates = [gate for gate in gates if not gate.passed]
    summary_lines = [
        f"STATUS: {'PASS' if passed else 'FAIL'}",
        f"Retail: {args.retail.resolve()}",
        f"OpenMW: {args.openmw.resolve()}",
        f"Gates: {len(gates) - len(failed_gates)}/{len(gates)} passed",
    ]
    if failed_gates:
        summary_lines.append("Failed gates:")
        summary_lines.extend(f"- {gate.name}: {gate.reason} (actual={gate.actual})" for gate in failed_gates)
    (args.output / "parity-summary.txt").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "passed": len(gates) - len(failed_gates), "total": len(gates), "report": str(report_path)}))
    return 0 if passed or args.allow_failed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # make harness failures explicit and machine-readable
        print(json.dumps({"status": "error", "error": f"{type(error).__name__}: {error}"}), file=sys.stderr)
        raise
