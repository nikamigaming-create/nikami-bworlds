#!/usr/bin/env python3
"""Offline FO3/FNV KF pose scorer.

This is deliberately outside the OpenMW runtime. It extracts/loads the raw
Fallout skeleton and KF files, samples controlled-block transforms, composes a
human skeleton pose under several rotation/translation assumptions, and writes
an anatomy ledger. The point is to make transform mistakes obvious before a
renderer or screenshot is involved.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

import numpy as np

if not hasattr(time, "clock"):
    time.clock = time.perf_counter  # pyffi 2.2.x compatibility on modern Python.

from pyffi.formats.nif import NifFormat  # noqa: E402


SENTINEL = -3.4028234663852886e38
SENTINEL_ABS = 1.0e30

MAJOR_BONES = {
    "bip01 head",
    "bip01 neck",
    "bip01 spine",
    "bip01 spine1",
    "bip01 spine2",
    "bip01 l upperarm",
    "bip01 r upperarm",
    "bip01 l forearm",
    "bip01 r forearm",
    "bip01 l thigh",
    "bip01 r thigh",
    "bip01 l calf",
    "bip01 r calf",
}


@dataclass
class ProfileScope:
    data_dirs: list[Path]
    archives: list[Path]


@dataclass
class Node:
    name: str
    lower: str
    parent: str | None
    children: list[str] = field(default_factory=list)
    translation: np.ndarray = field(default_factory=lambda: np.zeros(3))
    rotation: np.ndarray = field(default_factory=lambda: np.identity(3))


@dataclass
class Track:
    bone: str
    lower: str
    priority: int
    interp_type: str
    times: list[float]
    rotations: list[np.ndarray]
    translations: list[np.ndarray]
    base_rotation: np.ndarray | None = None
    base_translation: np.ndarray | None = None
    rotation_bspline: "BSplineChannel | None" = None
    translation_bspline: "BSplineChannel | None" = None


@dataclass
class BSplineChannel:
    start_time: float
    stop_time: float
    control_points: list[tuple[int, ...]]
    bias: float
    multiplier: float
    degree: int = 3


def norm_resource(path: str) -> str:
    return path.replace("/", "\\").strip("\\").lower()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_openmw_cfg(profile_dir: Path) -> ProfileScope:
    cfg = profile_dir / "openmw.cfg"
    if not cfg.exists():
        raise FileNotFoundError(f"openmw.cfg not found: {cfg}")

    data_dirs: list[Path] = []
    archive_names: list[str] = []
    for raw in cfg.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("data=") or line.startswith("data-local="):
            data_dirs.append(Path(line.split("=", 1)[1]))
        elif line.startswith("fallback-archive="):
            archive_names.append(line.split("=", 1)[1])

    archives: list[Path] = []
    for archive in archive_names:
        candidate = Path(archive)
        if candidate.is_absolute() and candidate.exists():
            archives.append(candidate)
            continue
        for data_dir in data_dirs:
            full = data_dir / archive
            if full.exists():
                archives.append(full)
                break

    return ProfileScope(data_dirs=data_dirs, archives=archives)


def run_bsatool(bsatool: Path, args: list[str]) -> list[str]:
    proc = subprocess.run(
        [str(bsatool), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"bsatool {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.splitlines()


def list_archive(bsatool: Path, archive: Path) -> list[str]:
    return [line.strip() for line in run_bsatool(bsatool, ["list", str(archive)]) if line.strip()]


def cache_path(cache_root: Path, archive: Path, resource: str) -> Path:
    digest = hashlib.sha1(str(archive).lower().encode("utf-8")).hexdigest()[:10]
    return cache_root / digest / resource.replace("\\", "/")


def resolve_or_extract(scope: ProfileScope, bsatool: Path, cache_root: Path, resource: str) -> tuple[Path, str, Path | None]:
    resource_norm = norm_resource(resource)
    for data_dir in scope.data_dirs:
        candidate = data_dir / resource_norm.replace("\\", os.sep)
        if candidate.exists():
            return candidate, "loose", None

    for archive in scope.archives:
        entries = getattr(resolve_or_extract, "_archive_entries", None)
        if entries is None:
            entries = {}
            setattr(resolve_or_extract, "_archive_entries", entries)
        archive_key = str(archive).lower()
        if archive_key not in entries:
            entries[archive_key] = {norm_resource(item): item for item in list_archive(bsatool, archive)}
        if resource_norm not in entries[archive_key]:
            continue

        exact_resource = entries[archive_key][resource_norm]
        archive_root = cache_root / hashlib.sha1(str(archive).lower().encode("utf-8")).hexdigest()[:10]
        target = archive_root / resource_norm.replace("\\", "/")
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            run_bsatool(bsatool, ["extract", "-f", str(archive), exact_resource, str(archive_root)])
            extracted = archive_root / exact_resource.replace("\\", os.sep)
            if extracted.exists() and extracted != target:
                target.parent.mkdir(parents=True, exist_ok=True)
                extracted.replace(target)
        if not target.exists():
            # bsatool creates the full hierarchy under the output root; tolerate either spelling.
            alt = archive_root / exact_resource.replace("\\", os.sep)
            if alt.exists():
                return alt, "archive", archive
            raise FileNotFoundError(f"Extraction did not produce {resource} from {archive}")
        return target, "archive", archive

    raise FileNotFoundError(f"Resource not found in profile scope: {resource}")


def load_nif(path: Path) -> NifFormat.Data:
    data = NifFormat.Data()
    with path.open("rb") as stream:
        data.read(stream)
    return data


def decode_name(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def vec3(value: Any) -> np.ndarray:
    return np.array([float(value.x), float(value.y), float(value.z)], dtype=float)


def matrix33(value: Any) -> np.ndarray:
    return np.array(
        [
            [float(value.m_11), float(value.m_12), float(value.m_13)],
            [float(value.m_21), float(value.m_22), float(value.m_23)],
            [float(value.m_31), float(value.m_32), float(value.m_33)],
        ],
        dtype=float,
    )


def quat_wxyz(value: Any) -> np.ndarray:
    if isinstance(value, tuple) or isinstance(value, list):
        q = np.array([float(value[0]), float(value[1]), float(value[2]), float(value[3])], dtype=float)
    else:
        q = np.array([float(value.w), float(value.x), float(value.y), float(value.z)], dtype=float)
    return normalize_quat(q)


def finite_vec(value: np.ndarray | None) -> bool:
    return value is not None and bool(np.all(np.isfinite(value))) and float(np.max(np.abs(value))) < SENTINEL_ABS


def finite_quat(value: np.ndarray | None) -> bool:
    return value is not None and bool(np.all(np.isfinite(value))) and float(np.max(np.abs(value))) < SENTINEL_ABS


def normalize_quat(q: np.ndarray) -> np.ndarray:
    if not np.all(np.isfinite(q)):
        return q
    length = float(np.linalg.norm(q))
    if length <= 1.0e-8:
        return np.array([1.0, 0.0, 0.0, 0.0], dtype=float)
    q = q / length
    if q[0] < 0.0:
        q = -q
    return q


def quat_to_matrix(q: np.ndarray) -> np.ndarray:
    q = normalize_quat(q)
    w, x, y, z = q
    return np.array(
        [
            [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w), 2.0 * (x * z + y * w)],
            [2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w)],
            [2.0 * (x * z - y * w), 2.0 * (y * z + x * w), 1.0 - 2.0 * (x * x + y * y)],
        ],
        dtype=float,
    )


def matrix_to_quat(m: np.ndarray) -> np.ndarray:
    trace = float(np.trace(m))
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2.0
        return normalize_quat(np.array([0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s]))
    i = int(np.argmax([m[0, 0], m[1, 1], m[2, 2]]))
    if i == 0:
        s = math.sqrt(max(1.0 + m[0, 0] - m[1, 1] - m[2, 2], 0.0)) * 2.0
        return normalize_quat(np.array([(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s]))
    if i == 1:
        s = math.sqrt(max(1.0 + m[1, 1] - m[0, 0] - m[2, 2], 0.0)) * 2.0
        return normalize_quat(np.array([(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s]))
    s = math.sqrt(max(1.0 + m[2, 2] - m[0, 0] - m[1, 1], 0.0)) * 2.0
    return normalize_quat(np.array([(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s]))


def quat_angle_degrees(left: np.ndarray, right: np.ndarray) -> float:
    left = normalize_quat(left)
    right = normalize_quat(right)
    dot = abs(float(np.dot(left, right)))
    dot = max(-1.0, min(1.0, dot))
    return math.degrees(2.0 * math.acos(dot))


def transform_matrix(rotation: np.ndarray, translation: np.ndarray) -> np.ndarray:
    m = np.identity(4, dtype=float)
    m[:3, :3] = rotation
    m[:3, 3] = translation
    return m


def build_skeleton(data: NifFormat.Data) -> dict[str, Node]:
    nodes_by_name: dict[str, Node] = {}

    def visit(block: Any, parent_lower: str | None) -> None:
        name = decode_name(getattr(block, "name", ""))
        if not name:
            return
        lower = name.lower()
        if type(block).__name__ not in {"NiNode", "BSFadeNode"}:
            return
        node = nodes_by_name.get(lower)
        if node is None:
            node = Node(
                name=name,
                lower=lower,
                parent=parent_lower,
                translation=vec3(block.translation),
                rotation=matrix33(block.rotation),
            )
            nodes_by_name[lower] = node
        if parent_lower and lower not in nodes_by_name[parent_lower].children:
            nodes_by_name[parent_lower].children.append(lower)
        for child in getattr(block, "children", []):
            if child:
                visit(child, lower)

    for root in data.roots:
        visit(root, None)
    return nodes_by_name


def get_controlled_block_name(block: Any) -> str:
    for attr in ("target_name", "node_name"):
        value = decode_name(getattr(block, attr, ""))
        if value:
            return value
    try:
        value = decode_name(block.get_node_name())
        if value:
            return value
    except Exception:
        pass
    return ""


def make_bspline_channel(interp: Any, channel: str, element_size: int) -> BSplineChannel | None:
    offset = int(getattr(interp, f"{channel}_offset", 65535))
    if offset == 65535:
        return None
    basis_data = getattr(interp, "basis_data", None)
    spline_data = getattr(interp, "spline_data", None)
    if not basis_data or not spline_data:
        return None
    count = int(getattr(basis_data, "num_control_points", 0))
    if count <= 0:
        return None
    try:
        control_points = [tuple(int(value) for value in item) for item in spline_data.get_short_data(offset, count, element_size)]
    except Exception:
        return None
    if not control_points:
        return None
    return BSplineChannel(
        start_time=float(getattr(interp, "start_time", 0.0)),
        stop_time=float(getattr(interp, "stop_time", 0.0)),
        control_points=control_points,
        bias=float(getattr(interp, f"{channel}_bias", 0.0)),
        multiplier=float(getattr(interp, f"{channel}_multiplier", 1.0)),
    )


def bspline_knots(n: int, t: int) -> list[int]:
    knots: list[int] = []
    for j in range(n + t + 1):
        if j < t:
            knots.append(0)
        elif t <= j <= n:
            knots.append(j - t + 1)
        else:
            knots.append(n - t + 2)
    return knots


def bspline_blend(k: int, t: int, knots: list[int], value: float, memo: dict[tuple[int, int], float]) -> float:
    key = (k, t)
    if key in memo:
        return memo[key]
    if t == 1:
        result = 1.0 if knots[k] <= value < knots[k + 1] else 0.0
    elif knots[k + t - 1] == knots[k] and knots[k + t] == knots[k + 1]:
        result = 0.0
    elif knots[k + t - 1] == knots[k]:
        result = (knots[k + t] - value) / (knots[k + t] - knots[k + 1]) * bspline_blend(k + 1, t - 1, knots, value, memo)
    elif knots[k + t] == knots[k + 1]:
        result = (value - knots[k]) / (knots[k + t - 1] - knots[k]) * bspline_blend(k, t - 1, knots, value, memo)
    else:
        left = (value - knots[k]) / (knots[k + t - 1] - knots[k]) * bspline_blend(k, t - 1, knots, value, memo)
        right = (knots[k + t] - value) / (knots[k + t] - knots[k + 1]) * bspline_blend(k + 1, t - 1, knots, value, memo)
        result = left + right
    memo[key] = result
    return result


def evaluate_bspline(channel: BSplineChannel, sample_time: float) -> np.ndarray | None:
    control_points = channel.control_points
    nctrl = len(control_points)
    if nctrl == 0:
        return None
    degree = min(channel.degree, max(0, nctrl - 1))
    if degree <= 0 or channel.stop_time <= channel.start_time:
        raw = np.array(control_points[0], dtype=float) / 32767.0
        return raw * channel.multiplier + channel.bias

    interval = ((sample_time - channel.start_time) / (channel.stop_time - channel.start_time)) * float(nctrl - degree)
    if interval <= 0.0:
        interval = 0.0
    if interval >= float(nctrl - degree):
        raw = np.array(control_points[-1], dtype=float) / 32767.0
        return raw * channel.multiplier + channel.bias

    t = degree + 1
    n = nctrl - 1
    knots = bspline_knots(n, t)
    accum = np.zeros(len(control_points[0]), dtype=float)
    memo: dict[tuple[int, int], float] = {}
    for k, point_values in enumerate(control_points):
        weight = bspline_blend(k, t, knots, interval, memo)
        if weight == 0.0:
            continue
        accum += (np.array(point_values, dtype=float) / 32767.0) * weight
    return accum * channel.multiplier + channel.bias


def make_track(block: Any) -> Track | None:
    bone = get_controlled_block_name(block)
    if not bone:
        return None
    interp = getattr(block, "interpolator", None) or getattr(block, "controller", None)
    if interp is None:
        return None

    times: list[float] = []
    rotations: list[np.ndarray] = []
    translations: list[np.ndarray] = []
    base_rotation: np.ndarray | None = None
    base_translation: np.ndarray | None = None
    rotation_bspline: BSplineChannel | None = None
    translation_bspline: BSplineChannel | None = None

    if hasattr(interp, "rotation"):
        candidate = quat_wxyz(interp.rotation)
        if finite_quat(candidate):
            base_rotation = candidate
    if hasattr(interp, "translation"):
        candidate = vec3(interp.translation)
        if finite_vec(candidate):
            base_translation = candidate

    if hasattr(interp, "get_times"):
        try:
            times = [float(item) for item in interp.get_times()]
        except Exception:
            times = []
    if hasattr(interp, "get_rotations"):
        try:
            rotations = [quat_wxyz(item) for item in interp.get_rotations()]
        except Exception:
            rotations = []
    if hasattr(interp, "get_translations"):
        try:
            translations = [np.array([float(item[0]), float(item[1]), float(item[2])], dtype=float) for item in interp.get_translations()]
        except Exception:
            translations = []

    rotation_bspline = make_bspline_channel(interp, "rotation", 4)
    translation_bspline = make_bspline_channel(interp, "translation", 3)

    # Minimal support for uncompressed NiTransformData-backed interpolators.
    data = getattr(interp, "data", None)
    if data:
        try:
            qkeys = list(data.quaternion_keys)
            rotations = [quat_wxyz(key.value) for key in qkeys]
            times = [float(key.time) for key in qkeys]
        except Exception:
            pass
        try:
            tkeys = list(data.translations.keys)
            translations = [vec3(key.value) for key in tkeys]
            if not times:
                times = [float(key.time) for key in tkeys]
        except Exception:
            pass

    return Track(
        bone=bone,
        lower=bone.lower(),
        priority=int(getattr(block, "priority", 0)),
        interp_type=type(interp).__name__,
        times=times,
        rotations=rotations,
        translations=translations,
        base_rotation=base_rotation,
        base_translation=base_translation,
        rotation_bspline=rotation_bspline,
        translation_bspline=translation_bspline,
    )


def load_tracks(kf_data: NifFormat.Data) -> tuple[str, float, float, list[Track]]:
    if not kf_data.roots:
        return "", 0.0, 0.0, []
    root = kf_data.roots[0]
    if type(root).__name__ != "NiControllerSequence":
        return decode_name(getattr(root, "name", "")), 0.0, 0.0, []
    tracks = []
    for block in getattr(root, "controlled_blocks", []):
        track = make_track(block)
        if track:
            tracks.append(track)
    return decode_name(root.name), float(root.start_time), float(root.stop_time), tracks


def sample_indices(count: int, limit: int) -> list[int]:
    if count <= 0:
        return [0]
    if count <= limit:
        return list(range(count))
    return sorted({round(i * (count - 1) / (limit - 1)) for i in range(limit)})


def select_sample(values: list[Any], sample: int, max_count: int) -> Any | None:
    if not values:
        return None
    if max_count <= 1:
        index = 0
    else:
        index = round(sample * (len(values) - 1) / (max_count - 1))
    index = max(0, min(len(values) - 1, int(index)))
    return values[index]


def select_track_rotation(track: Track, sample: int, max_count: int, sample_time: float) -> np.ndarray | None:
    if track.rotation_bspline is not None:
        value = evaluate_bspline(track.rotation_bspline, sample_time)
        if value is not None:
            return normalize_quat(value)
    value = select_sample(track.rotations, sample, max_count)
    if value is not None:
        return value
    return track.base_rotation


def select_track_translation(track: Track, sample: int, max_count: int, sample_time: float) -> np.ndarray | None:
    if track.translation_bspline is not None:
        value = evaluate_bspline(track.translation_bspline, sample_time)
        if value is not None:
            return value
    value = select_sample(track.translations, sample, max_count)
    if value is not None:
        return value
    return track.base_translation


def compose_pose(nodes: dict[str, Node], tracks: dict[str, Track], sample: int, max_count: int, sample_time: float, mode: str) -> dict[str, np.ndarray]:
    world: dict[str, np.ndarray] = {}
    local_rot_cache: dict[str, np.ndarray] = {}

    def local_for(lower: str) -> tuple[np.ndarray, np.ndarray]:
        node = nodes[lower]
        bind_rot = node.rotation
        bind_trans = node.translation
        bind_quat = matrix_to_quat(bind_rot)
        track = tracks.get(lower)
        key_quat = None
        key_trans = None
        if track:
            key_quat = select_track_rotation(track, sample, max_count, sample_time)
            key_trans = select_track_translation(track, sample, max_count, sample_time)

        if not finite_quat(key_quat):
            rot = bind_rot
        else:
            key_rot = quat_to_matrix(key_quat)
            if mode == "key":
                rot = key_rot
            elif mode == "bind_key":
                rot = bind_rot @ key_rot
            elif mode == "key_bind":
                rot = key_rot @ bind_rot
            elif mode == "bind_inv_key":
                rot = np.linalg.inv(bind_rot) @ key_rot
            elif mode == "key_bind_inv":
                rot = key_rot @ np.linalg.inv(bind_rot)
            elif mode == "niftools_corrected":
                rot = np.linalg.inv(bind_rot) @ key_rot
            else:
                rot = key_rot

        if not finite_vec(key_trans):
            trans = bind_trans
        elif mode.endswith("_drop_trans"):
            trans = bind_trans
        elif mode == "niftools_corrected":
            trans = np.linalg.inv(bind_rot) @ (key_trans - bind_trans)
        else:
            trans = key_trans

        local_rot_cache[lower] = rot
        return rot, trans

    def visit(lower: str) -> np.ndarray:
        if lower in world:
            return world[lower]
        node = nodes[lower]
        rot, trans = local_for(lower)
        local = transform_matrix(rot, trans)
        if node.parent and node.parent in nodes:
            result = visit(node.parent) @ local
        else:
            result = local
        world[lower] = result
        return result

    for lower in nodes:
        visit(lower)
    return world


def point(world: dict[str, np.ndarray], name: str) -> np.ndarray | None:
    mat = world.get(name)
    if mat is None:
        return None
    return mat[:3, 3].copy()


def dist(a: np.ndarray | None, b: np.ndarray | None) -> float:
    if a is None or b is None:
        return float("nan")
    return float(np.linalg.norm(a - b))


def horizontal_dist(a: np.ndarray | None, b: np.ndarray | None) -> float:
    if a is None or b is None:
        return float("nan")
    d = a[:2] - b[:2]
    return float(np.linalg.norm(d))


def angle_degrees(a: np.ndarray | None, b: np.ndarray | None, c: np.ndarray | None) -> float:
    if a is None or b is None or c is None:
        return float("nan")
    left = a - b
    right = c - b
    denom = float(np.linalg.norm(left) * np.linalg.norm(right))
    if denom <= 1.0e-8:
        return 180.0
    dot = max(-1.0, min(1.0, float(np.dot(left, right) / denom)))
    return math.degrees(math.acos(dot))


def finite_number(value: float) -> bool:
    return math.isfinite(value) and abs(value) < SENTINEL_ABS


def score_pose(nodes: dict[str, Node], tracks: dict[str, Track], world: dict[str, np.ndarray], sample: int, max_count: int, sample_time: float) -> dict[str, Any]:
    bones = {
        "head": point(world, "bip01 head"),
        "pelvis": point(world, "bip01 pelvis"),
        "leftShoulder": point(world, "bip01 l upperarm"),
        "rightShoulder": point(world, "bip01 r upperarm"),
        "leftElbow": point(world, "bip01 l forearm"),
        "rightElbow": point(world, "bip01 r forearm"),
        "leftHand": point(world, "bip01 l hand"),
        "rightHand": point(world, "bip01 r hand"),
        "leftThigh": point(world, "bip01 l thigh"),
        "rightThigh": point(world, "bip01 r thigh"),
        "leftKnee": point(world, "bip01 l calf"),
        "rightKnee": point(world, "bip01 r calf"),
        "leftFoot": point(world, "bip01 l foot"),
        "rightFoot": point(world, "bip01 r foot"),
    }
    missing = [name for name, value in bones.items() if value is None or not np.all(np.isfinite(value))]
    if missing:
        return {
            "status": "fail",
            "reason": "missing_bone",
            "missingBones": missing,
        }

    shoulder_span = dist(bones["leftShoulder"], bones["rightShoulder"])
    hip_span = dist(bones["leftThigh"], bones["rightThigh"])
    elbow_span = dist(bones["leftElbow"], bones["rightElbow"])
    hand_span = dist(bones["leftHand"], bones["rightHand"])
    knee_span = dist(bones["leftKnee"], bones["rightKnee"])
    foot_spread = dist(bones["leftFoot"], bones["rightFoot"])
    left_upper = dist(bones["leftShoulder"], bones["leftElbow"])
    right_upper = dist(bones["rightShoulder"], bones["rightElbow"])
    left_forearm = dist(bones["leftElbow"], bones["leftHand"])
    right_forearm = dist(bones["rightElbow"], bones["rightHand"])
    left_arm_reach = dist(bones["leftShoulder"], bones["leftHand"])
    right_arm_reach = dist(bones["rightShoulder"], bones["rightHand"])
    left_arm_angle = angle_degrees(bones["leftShoulder"], bones["leftElbow"], bones["leftHand"])
    right_arm_angle = angle_degrees(bones["rightShoulder"], bones["rightElbow"], bones["rightHand"])
    left_thigh = dist(bones["leftThigh"], bones["leftKnee"])
    right_thigh = dist(bones["rightThigh"], bones["rightKnee"])
    left_calf = dist(bones["leftKnee"], bones["leftFoot"])
    right_calf = dist(bones["rightKnee"], bones["rightFoot"])
    left_leg_angle = angle_degrees(bones["leftThigh"], bones["leftKnee"], bones["leftFoot"])
    right_leg_angle = angle_degrees(bones["rightThigh"], bones["rightKnee"], bones["rightFoot"])
    left_foot_from_hip = horizontal_dist(bones["leftFoot"], bones["leftThigh"])
    right_foot_from_hip = horizontal_dist(bones["rightFoot"], bones["rightThigh"])
    left_knee_from_hip = horizontal_dist(bones["leftKnee"], bones["leftThigh"])
    right_knee_from_hip = horizontal_dist(bones["rightKnee"], bones["rightThigh"])
    left_foot_drop = float(bones["leftThigh"][2] - bones["leftFoot"][2])
    right_foot_drop = float(bones["rightThigh"][2] - bones["rightFoot"][2])
    left_knee_drop = float(bones["leftThigh"][2] - bones["leftKnee"][2])
    right_knee_drop = float(bones["rightThigh"][2] - bones["rightKnee"][2])
    feet_below_pelvis = float(bones["pelvis"][2] - ((bones["leftFoot"][2] + bones["rightFoot"][2]) * 0.5))
    head_above_pelvis = float(bones["head"][2] - bones["pelvis"][2])
    avg_foot_from_hip = (left_foot_from_hip + right_foot_from_hip) * 0.5
    avg_knee_from_hip = (left_knee_from_hip + right_knee_from_hip) * 0.5
    avg_foot_drop = (left_foot_drop + right_foot_drop) * 0.5
    avg_knee_drop = (left_knee_drop + right_knee_drop) * 0.5

    max_rotation_delta = 0.0
    max_rotation_bone = ""
    for lower, track in tracks.items():
        if lower not in MAJOR_BONES or lower not in nodes:
            continue
        key = select_track_rotation(track, sample, max_count, sample_time)
        if not finite_quat(key):
            continue
        delta = quat_angle_degrees(matrix_to_quat(nodes[lower].rotation), key)
        if delta > max_rotation_delta:
            max_rotation_delta = delta
            max_rotation_bone = track.bone

    reason = "ok"
    if shoulder_span < 16.0 or shoulder_span > 48.0:
        reason = "shoulder_span"
    elif hand_span > max(62.0, shoulder_span * 2.25) or elbow_span > max(58.0, shoulder_span * 2.1):
        reason = "arm_span"
    elif min(left_upper, right_upper, left_forearm, right_forearm) < 8.0 or max(left_upper, right_upper, left_forearm, right_forearm) > 30.0:
        reason = "arm_lengths"
    elif left_arm_reach < 12.0 or right_arm_reach < 12.0 or abs(left_arm_reach - right_arm_reach) > 18.0:
        reason = "arm_reach"
    elif left_arm_angle < 20.0 or right_arm_angle < 20.0:
        reason = "arm_angle"
    elif min(left_thigh, right_thigh, left_calf, right_calf) < 16.0 or max(left_thigh, right_thigh, left_calf, right_calf) > 46.0:
        reason = "leg_lengths"
    elif avg_foot_drop < 48.0 or avg_foot_drop > 74.0 or avg_knee_drop < 18.0 or avg_knee_drop > 46.0:
        reason = "leg_crouch"
    elif avg_foot_from_hip > 28.0 or avg_knee_from_hip > 30.0:
        reason = "leg_travel"
    elif foot_spread > max(38.0, hip_span * 2.0) or foot_spread < 0.5 or knee_span > max(42.0, hip_span * 2.2):
        reason = "leg_spread"
    elif left_leg_angle < 75.0 or right_leg_angle < 75.0:
        reason = "leg_angle"
    elif head_above_pelvis < 35.0 or head_above_pelvis > 70.0 or feet_below_pelvis < 45.0 or feet_below_pelvis > 76.0:
        reason = "body_stack"
    elif max_rotation_delta > 170.0:
        reason = "major_rotation_from_bind"

    values = {
        "shoulderSpan": shoulder_span,
        "hipSpan": hip_span,
        "elbowSpan": elbow_span,
        "handSpan": hand_span,
        "handSpreadRatio": hand_span / max(1.0, shoulder_span),
        "kneeSpan": knee_span,
        "footSpread": foot_spread,
        "footSpreadRatio": foot_spread / max(1.0, hip_span),
        "leftUpperArm": left_upper,
        "rightUpperArm": right_upper,
        "leftForearm": left_forearm,
        "rightForearm": right_forearm,
        "leftArmReach": left_arm_reach,
        "rightArmReach": right_arm_reach,
        "leftArmAngle": left_arm_angle,
        "rightArmAngle": right_arm_angle,
        "leftThigh": left_thigh,
        "rightThigh": right_thigh,
        "leftCalf": left_calf,
        "rightCalf": right_calf,
        "leftLegAngle": left_leg_angle,
        "rightLegAngle": right_leg_angle,
        "avgFootFromHip": avg_foot_from_hip,
        "avgKneeFromHip": avg_knee_from_hip,
        "avgFootDrop": avg_foot_drop,
        "avgKneeDrop": avg_knee_drop,
        "feetBelowPelvis": feet_below_pelvis,
        "headAbovePelvis": head_above_pelvis,
        "maxMajorRotationFromBindDegrees": max_rotation_delta,
        "maxMajorRotationFromBindBone": max_rotation_bone,
    }

    for key, value in list(values.items()):
        if isinstance(value, float):
            values[key] = round(value, 4) if finite_number(value) else None

    return {
        "status": "pass" if reason == "ok" else "fail",
        "reason": reason,
        **values,
    }


def discover_kfs(scope: ProfileScope, bsatool: Path, pattern: str, limit: int) -> list[tuple[str, Path]]:
    regex = re.compile(pattern, re.IGNORECASE)
    found: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for archive in scope.archives:
        if "mesh" not in archive.name.lower() and "main" not in archive.name.lower():
            continue
        for entry in list_archive(bsatool, archive):
            resource = norm_resource(entry)
            if resource in seen or not regex.search(resource):
                continue
            seen.add(resource)
            found.append((resource, archive))
            if limit > 0 and len(found) >= limit:
                return found
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True, help="Proof manifest with profileDirectory.")
    parser.add_argument("--bsatool", type=Path, default=Path("local/openmw-fo4guard/bsatool.exe"))
    parser.add_argument("--output", type=Path, default=Path("run/offline-animation-harness/fallout-pose-sweep.jsonl"))
    parser.add_argument("--cache-root", type=Path, default=Path("run/offline-animation-harness/cache"))
    parser.add_argument("--skeleton", default=r"meshes\characters\_male\skeleton.nif")
    parser.add_argument("--kf-pattern", default=r"^meshes\\characters\\_male\\(locomotion|idleanims)\\.*\.kf$")
    parser.add_argument("--kf-limit", type=int, default=240)
    parser.add_argument("--samples-per-kf", type=int, default=12)
    parser.add_argument("--mode", action="append", default=None)
    args = parser.parse_args()

    repo = Path.cwd()
    bsatool = args.bsatool if args.bsatool.is_absolute() else repo / args.bsatool
    manifest = read_json(args.manifest)
    profile_dir = Path(manifest["profileDirectory"])
    scope = parse_openmw_cfg(profile_dir)
    args.cache_root.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    skeleton_path, skeleton_source, skeleton_archive = resolve_or_extract(scope, bsatool, args.cache_root, args.skeleton)
    skeleton_data = load_nif(skeleton_path)
    nodes = build_skeleton(skeleton_data)
    if "bip01 pelvis" not in nodes:
        raise RuntimeError(f"Skeleton did not expose expected Bip01 bones: {skeleton_path}")

    modes = args.mode or [
        "key",
        "key_drop_trans",
        "bind_key",
        "bind_key_drop_trans",
        "key_bind",
        "key_bind_drop_trans",
        "bind_inv_key",
        "niftools_corrected",
    ]

    kfs = discover_kfs(scope, bsatool, args.kf_pattern, args.kf_limit)
    rows = []
    with args.output.open("w", encoding="utf-8", newline="\n") as out:
        for resource, archive in kfs:
            try:
                kf_path, source, resolved_archive = resolve_or_extract(scope, bsatool, args.cache_root, resource)
                kf_data = load_nif(kf_path)
                sequence_name, start_time, stop_time, track_list = load_tracks(kf_data)
                tracks = {track.lower: track for track in track_list if track.lower in nodes}
                max_count = max([len(track.times) for track in tracks.values()] + [1])
                for sample in sample_indices(max_count, args.samples_per_kf):
                    sample_time = start_time
                    if max_count > 1:
                        sample_time = start_time + (stop_time - start_time) * (sample / (max_count - 1))
                    for mode in modes:
                        pose = compose_pose(nodes, tracks, sample, max_count, sample_time, mode)
                        score = score_pose(nodes, tracks, pose, sample, max_count, sample_time)
                        row = {
                            "schemaVersion": 1,
                            "evidenceKind": "offline-fallout-pose-sweep",
                            "worldId": manifest.get("worldId"),
                            "manifest": str(args.manifest).replace("\\", "/"),
                            "profileDirectory": str(profile_dir).replace("\\", "/"),
                            "skeleton": args.skeleton.replace("\\", "/"),
                            "skeletonSource": skeleton_source,
                            "skeletonArchive": str(skeleton_archive).replace("\\", "/") if skeleton_archive else None,
                            "kf": resource.replace("\\", "/"),
                            "kfSource": source,
                            "kfArchive": str(resolved_archive).replace("\\", "/") if resolved_archive else None,
                            "sequence": sequence_name,
                            "sequenceStart": start_time,
                            "sequenceStop": stop_time,
                            "sampleIndex": sample,
                            "sampleCount": max_count,
                            "sampleTime": round(sample_time, 5),
                            "mode": mode,
                            "trackCount": len(track_list),
                            "matchedTrackCount": len(tracks),
                            "bsplineTrackCount": sum(1 for track in track_list if "BSpline" in track.interp_type),
                            **score,
                        }
                        out.write(json.dumps(row, separators=(",", ":")) + "\n")
                        rows.append(row)
            except Exception as exc:
                row = {
                    "schemaVersion": 1,
                    "evidenceKind": "offline-fallout-pose-sweep",
                    "worldId": manifest.get("worldId"),
                    "manifest": str(args.manifest).replace("\\", "/"),
                    "kf": resource.replace("\\", "/"),
                    "kfArchive": str(archive).replace("\\", "/"),
                    "status": "fail",
                    "reason": "parse_error",
                    "error": str(exc),
                }
                out.write(json.dumps(row, separators=(",", ":")) + "\n")
                rows.append(row)

    fail_count = sum(1 for row in rows if row.get("status") == "fail")
    by_mode: dict[str, dict[str, int]] = {}
    for row in rows:
        mode = str(row.get("mode", "parse_error"))
        by_mode.setdefault(mode, {"pass": 0, "fail": 0})
        by_mode[mode][str(row.get("status", "fail"))] = by_mode[mode].get(str(row.get("status", "fail")), 0) + 1

    print(f"Offline Fallout pose sweep wrote {len(rows)} rows to {args.output}")
    print(f"KFs: {len(kfs)}  failures: {fail_count}")
    for mode, counts in sorted(by_mode.items()):
        print(f"{mode:22s} pass={counts.get('pass', 0):5d} fail={counts.get('fail', 0):5d}")
    return 0 if rows else 2


if __name__ == "__main__":
    raise SystemExit(main())
