import json
import os
from pathlib import Path

import bpy
from mathutils import Vector


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
area = json.loads(area_path.read_text(encoding="utf-8"))
bpy.ops.wm.read_factory_settings(use_empty=True)


def bounds(objects):
    mins = Vector((float("inf"),) * 3)
    maxs = Vector((float("-inf"),) * 3)
    for obj in objects:
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            for index in range(3):
                mins[index] = min(mins[index], point[index])
                maxs[index] = max(maxs[index], point[index])
    return mins, maxs

for key in ("lak100d_18_0", "lak100d_19_0", "lak100d_22_0", "lak100d_23_0"):
    definition = area["terrain"]["patches"][key]
    bpy.ops.import_scene.gltf(filepath=str(root / definition["file"]), import_shading="NORMALS")
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    mins, maxs = bounds(objects)
    print("OPENDAO_TERRAIN_LOCAL", key, "record", definition["instances"][0]["position"], "bounds", tuple(mins), tuple(maxs))
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

environment = Path(os.environ["OPENDAO_ENVIRONMENT_GLB"])
bpy.ops.import_scene.gltf(filepath=str(environment), import_shading="NORMALS")
for key in ("lak100d_19_0", "lak100d_23_0"):
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH" and key in obj.name]
    mins, maxs = bounds(objects)
    print("OPENDAO_TERRAIN_COMPOSED", key, "bounds", tuple(mins), tuple(maxs))
    composed_points = {
        tuple(round(value, 3) for value in (obj.matrix_world @ vertex.co))
        for obj in objects
        for vertex in obj.data.vertices
    }
    before = set(bpy.context.scene.objects)
    definition = area["terrain"]["patches"][key]
    bpy.ops.import_scene.gltf(filepath=str(root / definition["file"]), import_shading="NORMALS")
    individual = [obj for obj in bpy.context.scene.objects if obj not in before and obj.type == "MESH"]
    position = Vector(definition["instances"][0]["position"])
    individual_points = {
        tuple(round(value, 3) for value in (position + obj.matrix_world @ vertex.co))
        for obj in individual
        for vertex in obj.data.vertices
    }
    overlap = len(composed_points & individual_points)
    print(
        "OPENDAO_TERRAIN_VERTEX_PARITY",
        key,
        "composed",
        len(composed_points),
        "individual",
        len(individual_points),
        "overlap",
        overlap,
    )
    for obj in individual:
        bpy.data.objects.remove(obj, do_unlink=True)
