#!/usr/bin/env python3
"""Identify the float-composition contract used by an xNVSE pose snapshot."""

from __future__ import annotations

import argparse
import re
import struct
from dataclasses import dataclass
from pathlib import Path


NODE_RE = re.compile(
    r'^node "(?P<name>[^"]+)" parent "(?P<parent>[^"]+)" '
    r'local (?P<local>.+?) world (?P<world>.+)$'
)


def float_from_bits(token: str) -> float:
    return struct.unpack("<f", struct.pack("<I", int(token, 16)))[0]


def bits_from_float(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def f32(value: float) -> float:
    return float_from_bits(f"0x{bits_from_float(value):08X}")


@dataclass(frozen=True)
class Transform:
    rotation: tuple[float, ...]
    translation: tuple[float, ...]
    scale: float


@dataclass(frozen=True)
class Node:
    name: str
    parent: str
    local: Transform
    world: Transform


def parse_transform(tokens: list[str]) -> Transform:
    if len(tokens) != 13:
        raise ValueError(f"expected 13 transform words, got {len(tokens)}")
    values = tuple(float_from_bits(token) for token in tokens)
    return Transform(values[:9], values[9:12], values[12])


def load_snapshot(path: Path) -> list[Node]:
    nodes: list[Node] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.startswith("node "):
            continue
        match = NODE_RE.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid node row at {path}:{line_number}")
        nodes.append(
            Node(
                match.group("name"),
                match.group("parent"),
                parse_transform(match.group("local").split()),
                parse_transform(match.group("world").split()),
            )
        )
    if not nodes:
        raise ValueError(f"no nodes in {path}")
    return nodes


def dot(left: tuple[float, ...], right: tuple[float, ...], profile: str) -> float:
    if profile == "round-end":
        return f32(sum(a * b for a, b in zip(left, right)))
    if profile == "round-ops":
        result = f32(left[0] * right[0])
        for a, b in zip(left[1:], right[1:]):
            result = f32(result + f32(a * b))
        return result
    raise ValueError(profile)


def matrix_product(left: tuple[float, ...], right: tuple[float, ...], profile: str) -> tuple[float, ...]:
    result: list[float] = []
    for row in range(3):
        for column in range(3):
            result.append(
                dot(
                    tuple(left[row * 3 + axis] for axis in range(3)),
                    tuple(right[axis * 3 + column] for axis in range(3)),
                    profile,
                )
            )
    return tuple(result)


def row_vector_product(vector: tuple[float, ...], matrix: tuple[float, ...], profile: str) -> tuple[float, ...]:
    return tuple(
        dot(vector, tuple(matrix[row * 3 + column] for row in range(3)), profile)
        for column in range(3)
    )


def column_vector_product(matrix: tuple[float, ...], vector: tuple[float, ...], profile: str) -> tuple[float, ...]:
    return tuple(
        dot(tuple(matrix[row * 3 + column] for column in range(3)), vector, profile)
        for row in range(3)
    )


def add_translation(left: tuple[float, ...], right: tuple[float, ...], profile: str) -> tuple[float, ...]:
    if profile == "round-end":
        return tuple(f32(a + b) for a, b in zip(left, right))
    return tuple(f32(a + b) for a, b in zip(left, right))


def multiply_scale(vector: tuple[float, ...], scale: float) -> tuple[float, ...]:
    return tuple(f32(value * scale) for value in vector)


def compose(parent: Transform, local: Transform, order: str, profile: str) -> Transform:
    if order == "parent-local":
        rotation = matrix_product(parent.rotation, local.rotation, profile)
        rotated = column_vector_product(parent.rotation, local.translation, profile)
    elif order == "local-parent":
        rotation = matrix_product(local.rotation, parent.rotation, profile)
        rotated = row_vector_product(local.translation, parent.rotation, profile)
    else:
        raise ValueError(order)
    translation = add_translation(multiply_scale(rotated, parent.scale), parent.translation, profile)
    return Transform(rotation, translation, f32(parent.scale * local.scale))


def ordered_int(bits: int) -> int:
    return 0x80000000 - bits if bits & 0x80000000 else 0x80000000 + bits


def ulp_distance(actual: float, expected: float) -> int:
    return abs(ordered_int(bits_from_float(actual)) - ordered_int(bits_from_float(expected)))


def evaluate(nodes: list[Node], order: str, profile: str) -> tuple[int, int, int, str, int]:
    calculated: dict[str, Transform] = {}
    mismatches = 0
    components = 0
    max_ulp = 0
    max_node = ""
    exact_nodes = 0
    for node in nodes:
        if node.parent == "None":
            actual = node.local
        else:
            actual = compose(calculated[node.parent], node.local, order, profile)
        calculated[node.name] = actual
        node_exact = True
        for actual_value, expected_value in zip(
            actual.rotation + actual.translation + (actual.scale,),
            node.world.rotation + node.world.translation + (node.world.scale,),
        ):
            components += 1
            distance = ulp_distance(actual_value, expected_value)
            if distance:
                mismatches += 1
                node_exact = False
            if distance > max_ulp:
                max_ulp = distance
                max_node = node.name
        exact_nodes += 1 if node_exact else 0
    return mismatches, components, exact_nodes, max_node, max_ulp


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    nodes = load_snapshot(args.snapshot)
    print(f"snapshot={args.snapshot} nodes={len(nodes)}")
    for order in ("parent-local", "local-parent"):
        for profile in ("round-end", "round-ops"):
            mismatches, components, exact_nodes, max_node, max_ulp = evaluate(nodes, order, profile)
            print(
                f"order={order} profile={profile} componentMismatches={mismatches}/{components} "
                f"exactNodes={exact_nodes}/{len(nodes)} maxUlp={max_ulp} maxUlpNode={max_node!r}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
