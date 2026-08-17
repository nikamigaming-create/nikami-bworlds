#!/usr/bin/env python3
"""Score every proper signed axis permutation against the native FNV hand/Weapon bind.

This is an offline oracle.  It never launches either engine and never writes game state.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import time
from pathlib import Path

import numpy as np

# PyFFI still imports time.clock on Python 3.11.
if not hasattr(time, "clock"):
    time.clock = time.perf_counter  # type: ignore[attr-defined]

from pyffi.formats.nif import NifFormat  # noqa: E402


def block_name(block) -> str:
    value = getattr(block, "name", b"")
    return bytes(value).decode("utf-8", errors="replace") if value else ""


def load_nif(path: Path):
    data = NifFormat.Data()
    with path.open("rb") as stream:
        data.read(stream)
    return data


def matrix44(value) -> np.ndarray:
    return np.array(
        [[float(getattr(value, f"m_{row}{column}")) for column in range(1, 5)] for row in range(1, 5)],
        dtype=float,
    )


def transform_for(data, node_name: str) -> np.ndarray:
    root = data.roots[0]
    for block in data.blocks:
        if block_name(block) == node_name and hasattr(block, "get_transform"):
            return matrix44(block.get_transform(root))
    raise RuntimeError(f"missing NIF node {node_name!r}")


def point_in_frame(world: np.ndarray, inverse_frame: np.ndarray) -> np.ndarray:
    return (np.array([0.0, 0.0, 0.0, 1.0]) @ world @ inverse_frame)[:3]


def normalize(value: np.ndarray) -> np.ndarray:
    length = float(np.linalg.norm(value))
    if length <= 1e-9:
        raise RuntimeError("zero-length fixture axis")
    return value / length


def proper_signed_permutations():
    for permutation in itertools.permutations(range(3)):
        for signs in itertools.product((-1, 1), repeat=3):
            matrix = np.zeros((3, 3), dtype=float)
            for source_axis, target_axis in enumerate(permutation):
                matrix[source_axis, target_axis] = signs[source_axis]
            determinant = float(np.linalg.det(matrix))
            if determinant > 0.5:
                yield permutation, signs, matrix


def axis_label(permutation, signs) -> str:
    names = ("X", "Y", "Z")
    return ",".join(
        f"{names[source]}->{('+' if signs[source] > 0 else '-')}{names[target]}"
        for source, target in enumerate(permutation)
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def trigger_center(landmarks: list[dict]) -> np.ndarray | None:
    candidates = [
        item for item in landmarks
        if "trigger" in item.get("name", "").lower() and "center" in item
    ]
    if not candidates:
        return None
    return np.array(candidates[0]["center"], dtype=float)


def model_forward(path: Path) -> tuple[np.ndarray, str]:
    data = load_nif(path)
    try:
        projectile = transform_for(data, "ProjectileNode")
        return normalize(np.array([0.0, 1.0, 0.0]) @ projectile[:3, :3]), "ProjectileNode+Y"
    except RuntimeError:
        return np.array([0.0, 1.0, 0.0]), "melee-model+Y"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skeleton", required=True, type=Path)
    parser.add_argument("--weapon-landmarks", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    skeleton = load_nif(args.skeleton)
    right_hand_world = transform_for(skeleton, "Bip01 R Hand")
    weapon_world = transform_for(skeleton, "Weapon")
    inverse_right_hand = np.linalg.inv(right_hand_world)
    weapon_to_hand = weapon_world @ inverse_right_hand

    index_root = point_in_frame(transform_for(skeleton, "Bip01 R Finger1"), inverse_right_hand)
    thumb_web = point_in_frame(transform_for(skeleton, "Bip01 R Thumb11"), inverse_right_hand)
    index_tip = point_in_frame(transform_for(skeleton, "Bip01 R Finger12"), inverse_right_hand)
    palm_web = (index_root + thumb_web) * 0.5
    native_weapon_origin = weapon_to_hand[3, :3]

    # Original OpenMW-VR TrackingController base orientation: +90 degrees around Z.
    base_orientation = np.array(
        [[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]], dtype=float
    )
    target_forward = np.array([0.0, 1.0, 0.0])
    permutations = list(proper_signed_permutations())
    if len(permutations) != 24:
        raise RuntimeError(f"expected 24 proper signed permutations, got {len(permutations)}")

    landmark_report = json.loads(args.weapon_landmarks.read_text(encoding="utf-8"))
    results = []
    for weapon in landmark_report["weapons"]:
        path = Path(weapon["path"])
        forward, forward_source = model_forward(path)
        trigger = trigger_center(weapon.get("landmarks", []))
        candidates = []
        for permutation, signs, adapter in permutations:
            rendered_forward = normalize(
                forward @ adapter @ weapon_to_hand[:3, :3] @ base_orientation
            )
            forward_dot = float(np.clip(rendered_forward @ target_forward, -1.0, 1.0))
            forward_angle = math.degrees(math.acos(forward_dot))
            trigger_distance = None
            if trigger is not None:
                trigger_in_hand = trigger @ adapter @ weapon_to_hand[:3, :3] + native_weapon_origin
                trigger_distance = float(np.linalg.norm(trigger_in_hand - index_tip))
            # Forward is a hard functional constraint. Trigger proximity breaks the four possible barrel rolls.
            score = forward_angle * 4.0 + (trigger_distance if trigger_distance is not None else 0.0)
            candidates.append(
                {
                    "axisMap": axis_label(permutation, signs),
                    "matrixRows": adapter.tolist(),
                    "determinant": float(np.linalg.det(adapter)),
                    "forwardDot": forward_dot,
                    "forwardAngleDegrees": forward_angle,
                    "triggerToIndexDistance": trigger_distance,
                    "score": score,
                    "identity": bool(np.array_equal(adapter, np.eye(3))),
                }
            )
        candidates.sort(key=lambda item: (item["score"], not item["identity"], item["axisMap"]))
        winner = candidates[0]
        results.append(
            {
                "path": str(path.resolve()),
                "sha256": sha256(path),
                "forwardSource": forward_source,
                "modelForward": forward.tolist(),
                "winner": winner,
                "all24": candidates,
                "accepted": trigger is not None and winner["identity"],
                "acceptanceReason": (
                    "identity wins both native forward and trigger/index constraints"
                    if trigger is not None and winner["identity"]
                    else "family animation/second signed landmark required before accepting melee roll"
                ),
            }
        )

    report = {
        "schema": "nikami-fnv-native-weapon-attachment-permutations/v1",
        "skeleton": {"path": str(args.skeleton.resolve()), "sha256": sha256(args.skeleton)},
        "properSignedPermutationCount": len(permutations),
        "rightHandTrackingOracle": "OpenMW-VR +90Z base orientation followed by RightHandAim",
        "nativeWeaponOriginInRightHand": native_weapon_origin.tolist(),
        "nativePalmWebInRightHand": palm_web.tolist(),
        "nativeWeaponOriginToPalmDistance": float(np.linalg.norm(native_weapon_origin - palm_web)),
        "nativeIndexTipInRightHand": index_tip.tolist(),
        "weapons": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=False)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
