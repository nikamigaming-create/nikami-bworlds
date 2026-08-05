"""Build the exact clean Redcliffe lake surface used by the Godot runtime.

The generated glTF is deliberately dependency-free so the native OpenMW
proof does not depend on Blender. Coordinates remain in Godot/glTF Y-up space;
OpenMW's glTF loader performs the normal Z-up conversion.
"""

import json
import struct
from pathlib import Path


OUTPUT = Path(r"D:\code\nikami-worlds\local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-authored-water.glb")

# Godot telemetry: AABB P=(-240,0,-306), S=(1000,.00001,1000), with the
# replacement surface at Y=.01001. A 64x64 grid gives the shader sufficient
# vertices for future displacement while preserving the exact rectangle.
segments = 64
positions = []
normals = []
uvs = []
indices = []
for z_index in range(segments + 1):
    vz = -306.0 + 1000.0 * z_index / segments
    for x_index in range(segments + 1):
        vx = -240.0 + 1000.0 * x_index / segments
        positions.extend((vx, 0.01001, vz))
        normals.extend((0.0, 1.0, 0.0))
        uvs.extend((x_index / segments, z_index / segments))
for z_index in range(segments):
    for x_index in range(segments):
        a = z_index * (segments + 1) + x_index
        b = a + 1
        c = a + segments + 1
        d = c + 1
        indices.extend((a, c, b, b, c, d))

chunks = []
views = []


def add_chunk(values, fmt, target):
    while sum(map(len, chunks)) % 4:
        chunks.append(b"\0")
    offset = sum(map(len, chunks))
    data = struct.pack("<" + fmt * len(values), *values)
    chunks.append(data)
    views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(data), "target": target})
    return len(views) - 1


position_view = add_chunk(positions, "f", 34962)
normal_view = add_chunk(normals, "f", 34962)
uv_view = add_chunk(uvs, "f", 34962)
index_view = add_chunk(indices, "I", 34963)
binary = b"".join(chunks)

document = {
    "asset": {"version": "2.0", "generator": "OpenDAO clean-water parity builder"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "OpenDAO_Water::CleanLakeSurface", "mesh": 0}],
    "meshes": [{"name": "OpenDAO_Water::CleanLakeSurface", "primitives": [{
        "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
        "indices": 3,
        "material": 0,
    }]}],
    "materials": [{
        "name": "OpenDAO_Water::CleanLakeSurface",
        "pbrMetallicRoughness": {
            "baseColorFactor": [0.025, 0.105, 0.145, 0.91],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.18,
        },
        "alphaMode": "BLEND",
        "doubleSided": True,
    }],
    "buffers": [{"byteLength": len(binary)}],
    "bufferViews": views,
    "accessors": [
        {"bufferView": position_view, "componentType": 5126, "count": len(positions) // 3,
         "type": "VEC3", "min": [-240.0, 0.01001, -306.0], "max": [760.0, 0.01001, 694.0]},
        {"bufferView": normal_view, "componentType": 5126, "count": len(normals) // 3, "type": "VEC3"},
        {"bufferView": uv_view, "componentType": 5126, "count": len(uvs) // 2, "type": "VEC2"},
        {"bufferView": index_view, "componentType": 5125, "count": len(indices), "type": "SCALAR"},
    ],
}

json_bytes = json.dumps(document, separators=(",", ":")).encode("utf-8")
json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
binary += b"\0" * ((4 - len(binary) % 4) % 4)
glb = (
    struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(json_bytes) + 8 + len(binary))
    + struct.pack("<II", len(json_bytes), 0x4E4F534A) + json_bytes
    + struct.pack("<II", len(binary), 0x004E4942) + binary
)
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_bytes(glb)
print(f"OPENDAO_CLEAN_WATER output={OUTPUT} vertices={len(positions)//3} triangles={len(indices)//3}")
