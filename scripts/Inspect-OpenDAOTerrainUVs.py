"""Audit Haven terrain UV domains and material assignments in Blender."""

import json
import os
from pathlib import Path

import bpy


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
area = json.loads(area_path.read_text(encoding="utf-8"))
bpy.ops.wm.read_factory_settings(use_empty=True)

for key, definition in area.get("terrain", {}).get("patches", {}).items():
    model = root / definition["file"]
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(model), import_shading="NORMALS")
    imported = [obj for obj in bpy.context.scene.objects if obj not in before]
    for obj in imported:
        if obj.type != "MESH" or not obj.data.uv_layers.active:
            continue
        uv = [loop.uv[:] for loop in obj.data.uv_layers.active.data]
        if not uv:
            continue
        materials = ",".join(slot.material.name if slot.material else "" for slot in obj.material_slots)
        print(
            "OPENDAO_TERRAIN_UV",
            f"key={key}",
            f"mesh={obj.name}",
            f"umin={min(value[0] for value in uv):.9f}",
            f"umax={max(value[0] for value in uv):.9f}",
            f"vmin={min(value[1] for value in uv):.9f}",
            f"vmax={max(value[1] for value in uv):.9f}",
            f"materials={materials}",
        )
    for obj in imported:
        bpy.data.objects.remove(obj, do_unlink=True)
