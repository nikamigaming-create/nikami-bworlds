"""Prepare the Godot-assembled Redcliffe scene for OpenMW's glTF reader."""

import json
import struct
from pathlib import Path


SOURCE = Path(r"D:\code\nikami-worlds\local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-runtime-exact.glb")
TARGET = Path(r"D:\code\nikami-worlds\local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-runtime-openmw.glb")

blob = SOURCE.read_bytes()
json_length, json_type = struct.unpack_from("<II", blob, 12)
if json_type != 0x4E4F534A:
    raise RuntimeError("missing GLB JSON chunk")
document = json.loads(blob[20:20 + json_length])
binary_header = 20 + json_length
binary_length, binary_type = struct.unpack_from("<II", blob, binary_header)
binary = blob[binary_header + 8:binary_header + 8 + binary_length]

# Runtime-baked actors are supplied through the pose-preserving foreground
# artifact. Suppress Godot's skinned copies so OpenMW does not show duplicates
# or bind poses.
actors = 0
for node in document.get("nodes", []):
    name = node.get("name", "")
    if name.startswith("arl100cr_"):
        node["scale"] = [0.0, 0.0, 0.0]
        actors += 1

# Godot hides the original kilometre lake shell after creating its clean
# surface. Preserve that visibility decision in the exported interchange.
for node in document.get("nodes", []):
    if node.get("name") in {"lak100d_water_122", "lak100d_water_12", "lak100d_water_12__lak100d_water_12"}:
        node["scale"] = [0.0, 0.0, 0.0]

# Mark the authored hydrology and clean plane for the native OpenDAO water
# shader. Godot shader materials intentionally export without PBR fields.
water_materials = set()
for mesh_index in (1528, 1530):
    for primitive in document["meshes"][mesh_index].get("primitives", []):
        water_materials.add(primitive["material"])
for material_index in water_materials:
    material = document["materials"][material_index]
    material["name"] = f"OpenDAO_Water::Runtime::{material_index}"
    material["doubleSided"] = True
    material["alphaMode"] = "BLEND"
    material["pbrMetallicRoughness"] = {
        "baseColorFactor": [0.025, 0.105, 0.145, 0.96],
        "metallicFactor": 0.0,
        "roughnessFactor": 0.18,
    }

json_bytes = json.dumps(document, separators=(",", ":")).encode("utf-8")
json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
binary += b"\0" * ((4 - len(binary) % 4) % 4)
output = (
    struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(json_bytes) + 8 + len(binary))
    + struct.pack("<II", len(json_bytes), 0x4E4F534A) + json_bytes
    + struct.pack("<II", len(binary), binary_type) + binary
)
TARGET.write_bytes(output)
print(f"OPENDAO_RUNTIME_PREP output={TARGET} actors_suppressed={actors} water_materials={len(water_materials)}")
