#!/usr/bin/env python3
"""Compare retail FNV skin constants with OpenMW's audited CPU palette."""

from __future__ import annotations

import argparse
import json
import re
import struct
from pathlib import Path

import numpy as np


BONE_RE = re.compile(
    r'retail skin palette bone:.*?index=(\d+) name="([^"]+)" '
    r'paletteBits=\[([^]]+)\] invBindBits=\[([^]]+)\] skeletonBits=\[([^]]+)\]'
)
HEADER_RE = re.compile(r'retail skin palette audit:.*?skinTransformBits=\[([^]]+)\]')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retail-ledger", type=Path, required=True)
    parser.add_argument("--sequence", type=int, default=938)
    parser.add_argument("--openmw-log", type=Path, required=True)
    return parser.parse_args()


def bits_matrix(text: str) -> np.ndarray:
    values = [
        struct.unpack("<f", struct.pack("<I", int(token.strip(), 16)))[0]
        for token in text.split(",")
    ]
    if len(values) != 16:
        raise RuntimeError(f"Expected 16 matrix words, got {len(values)}")
    return np.asarray(values, dtype=np.float32).reshape(4, 4)


def retail_bones(path: Path, sequence: int) -> np.ndarray:
    with path.open("r", encoding="utf-8") as source:
        for raw in source:
            event = json.loads(raw)
            if event.get("event") != "draw" or int(event.get("sequence", -1)) != sequence:
                continue
            registers = event["constants"]["vsFloat"]
            result = np.asarray([registers[index] for index in range(44, 59)], dtype=np.float32)
            return result.reshape(5, 3, 4)
    raise RuntimeError(f"Retail draw sequence {sequence} not found")


def openmw_matrices(path: Path) -> tuple[np.ndarray, list[dict[str, object]]]:
    header: np.ndarray | None = None
    bones: dict[int, dict[str, object]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if match := HEADER_RE.search(line):
            header = bits_matrix(match.group(1))
        if match := BONE_RE.search(line):
            index = int(match.group(1))
            bones[index] = {
                "name": match.group(2),
                "palette": bits_matrix(match.group(3)),
                "invBind": bits_matrix(match.group(4)),
                "skeleton": bits_matrix(match.group(5)),
            }
    if header is None or sorted(bones) != list(range(5)):
        raise RuntimeError(f"Incomplete OpenMW palette audit: header={header is not None}, bones={sorted(bones)}")
    return header, [bones[index] for index in range(5)]


def f32_mul(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    # Numpy's float32 dot keeps each stored result at float32, which is sufficient
    # for ranking composition candidates. The runtime byte gate remains authoritative.
    return np.matmul(left.astype(np.float32), right.astype(np.float32), dtype=np.float32)


def as_retail_rows(osg_matrix: np.ndarray) -> np.ndarray:
    # OSG preMult(Vec3) uses row-vector storage; D3D's shader constants are three
    # column-vector rows. Transposition puts both contracts in the same layout.
    return osg_matrix.T[:3, :]


def main() -> int:
    args = parse_args()
    retail = retail_bones(args.retail_ledger, args.sequence)
    skin_transform, bones = openmw_matrices(args.openmw_log)

    candidates: dict[str, list[np.ndarray]] = {
        "palette": [],
        "palette*skin": [],
        "skin*palette": [],
        "invBind*skeleton": [],
        "invBind*skeleton*skin": [],
        "skeleton*invBind": [],
        "skeleton*invBind*skin": [],
    }
    for bone in bones:
        palette = bone["palette"]
        inv_bind = bone["invBind"]
        skeleton = bone["skeleton"]
        inv_then_skeleton = f32_mul(inv_bind, skeleton)
        skeleton_then_inv = f32_mul(skeleton, inv_bind)
        candidates["palette"].append(palette)
        candidates["palette*skin"].append(f32_mul(palette, skin_transform))
        candidates["skin*palette"].append(f32_mul(skin_transform, palette))
        candidates["invBind*skeleton"].append(inv_then_skeleton)
        candidates["invBind*skeleton*skin"].append(f32_mul(inv_then_skeleton, skin_transform))
        candidates["skeleton*invBind"].append(skeleton_then_inv)
        candidates["skeleton*invBind*skin"].append(f32_mul(skeleton_then_inv, skin_transform))

    scored: list[tuple[float, float, str, np.ndarray]] = []
    for name, values in candidates.items():
        converted = np.asarray([as_retail_rows(value) for value in values], dtype=np.float32)
        absolute = np.abs(converted - retail)
        scored.append((float(np.max(absolute)), float(np.mean(absolute)), name, converted))
    scored.sort(key=lambda value: (value[0], value[1]))

    for maximum, mean, name, converted in scored:
        bone_max = np.max(np.abs(converted - retail), axis=(1, 2))
        print(
            f"{name:28s} max={maximum:.9g} mean={mean:.9g} "
            + " boneMax=["
            + ",".join(f"{value:.9g}" for value in bone_max)
            + "]"
        )

    print("GLOBAL_RELATIONS")
    retail4 = np.zeros((5, 4, 4), dtype=np.float64)
    retail4[:, :3, :] = retail
    retail4[:, 3, 3] = 1.0
    relation_scores: list[tuple[float, str, str, np.ndarray]] = []
    for name, values in candidates.items():
        openmw4 = np.asarray([value.T for value in values], dtype=np.float64)
        left = np.asarray([retail4[i] @ np.linalg.inv(openmw4[i]) for i in range(5)])
        right = np.asarray([np.linalg.inv(openmw4[i]) @ retail4[i] for i in range(5)])
        for relation_name, relation in (("left", left), ("right", right)):
            spread = float(np.max(np.abs(relation - relation[0])))
            relation_scores.append((spread, name, relation_name, relation[0]))
    relation_scores.sort(key=lambda value: value[0])
    for spread, name, relation_name, matrix in relation_scores[:8]:
        print(f"{name:28s} {relation_name:5s} spread={spread:.9g}")
        print(np.array2string(matrix, precision=9, separator=","))

    best = scored[0]
    print(f"BEST={best[2]}")
    for index, bone in enumerate(bones):
        print(f"bone[{index}]={bone['name']}")
        print(" retail=" + np.array2string(retail[index], precision=9, separator=","))
        print(" openmw=" + np.array2string(best[3][index], precision=9, separator=","))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
