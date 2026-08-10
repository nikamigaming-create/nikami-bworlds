#!/usr/bin/env python3
"""Correlate suspicious bright framebuffer regions with projected FNV placements."""

from __future__ import annotations

import json
import math
import sys
from collections import deque
from pathlib import Path

from PIL import Image


def norm(v):
    length = math.sqrt(sum(x * x for x in v))
    return tuple(x / length for x in v)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


image_path, ring_path = map(Path, sys.argv[1:3])
threshold = int(sys.argv[3]) if len(sys.argv) > 3 else 225
image = Image.open(image_path).convert("RGB")
width, height = image.size
pixels = image.load()
mask = {
    (x, y)
    for y in range(70, height - 45)
    for x in range(width)
    if max(pixels[x, y]) >= threshold and min(pixels[x, y]) >= max(100, threshold - 75)
}
components = []
while mask:
    seed = mask.pop()
    queue = deque([seed])
    points = [seed]
    while queue:
        x, y = queue.popleft()
        for point in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if point in mask:
                mask.remove(point)
                queue.append(point)
                points.append(point)
    if len(points) >= 6:
        components.append((len(points), sum(x for x, _ in points) / len(points), sum(y for _, y in points) / len(points)))

camera = (-10.0, 32.0, -10.0)
target = (58.0, 3.5, -82.0)
forward = norm(sub(target, camera))
right = norm(cross(forward, (0.0, 1.0, 0.0)))
up = cross(right, forward)
tan_half = math.tan(math.radians(68.0) / 2.0)
aspect = width / height
ring = json.loads(ring_path.read_text(encoding="utf-8"))
origin = (-72392.8438, -1240.19275, 8137.58643)
projected = []
for cell in ring["cells"]:
    for placement in cell["placements"]:
        sx, sy, sz = placement["position"]
        world = ((sx - origin[0]) / 70.0, (sz - origin[2]) / 70.0, -(sy - origin[1]) / 70.0)
        relative = sub(world, camera)
        depth = dot(relative, forward)
        if depth <= 0.1:
            continue
        px = width * (0.5 + dot(relative, right) / (2.0 * depth * tan_half * aspect))
        py = height * (0.5 - dot(relative, up) / (2.0 * depth * tan_half))
        projected.append((px, py, depth, placement["model"], placement.get("base_type", "")))

for size, x, y in sorted(components, reverse=True)[:40]:
    nearest = sorted(projected, key=lambda item: math.hypot(item[0] - x, item[1] - y))[:4]
    print(f"bright pixels={size:5d} center={x:7.1f},{y:6.1f}")
    for px, py, depth, model, kind in nearest:
        print(f"  delta={math.hypot(px-x, py-y):5.1f} screen={px:7.1f},{py:6.1f} depth={depth:6.1f} {kind} {model}")
