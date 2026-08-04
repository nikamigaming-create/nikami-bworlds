import json
import math
import os
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
environment = Path(os.environ["OPENDAO_ENVIRONMENT_GLB"])
output = Path(os.environ["OPENDAO_PROBE_OUTPUT"])
area = json.loads(area_path.read_text(encoding="utf-8"))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(environment), import_shading="NORMALS")
for definition in area["terrain"]["patches"].values():
    p = definition["instances"][0]["position"]
    if ((p[0] - 260.0) ** 2 + (p[1] - 301.0) ** 2) ** 0.5 <= 85.0:
        continue
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(root / definition["file"]), import_shading="NORMALS")
    imported = [obj for obj in bpy.context.scene.objects if obj not in before]
    q = definition["instances"][0].get("rotation", [0, 0, 0, 1])
    placement = Matrix.Translation(Vector(p)) @ Quaternion((q[3], q[0], q[1], q[2])).to_matrix().to_4x4()
    for obj in imported:
        obj.matrix_world = placement @ obj.matrix_world

camera_data = bpy.data.cameras.new("ParityCamera")
camera = bpy.data.objects.new("ParityCamera", camera_data)
bpy.context.collection.objects.link(camera)
camera.location = Vector((250.0, 307.0, 3.78328))
target = Vector((264.0, 300.5, 2.5))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.angle = math.radians(72.0)
camera_data.clip_start = 0.05
camera_data.clip_end = 2000.0

scene = bpy.context.scene
scene.camera = camera
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "MATERIAL"
scene.display.shading.show_shadows = True
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = str(output)
scene.world = bpy.data.worlds.new("ParityWorld")
scene.world.color = (0.12, 0.14, 0.16)
bpy.ops.render.render(write_still=True)
combined_output = os.environ.get("OPENDAO_COMBINED_OBJ_OUTPUT", "")
if combined_output:
    bpy.data.objects.remove(camera, do_unlink=True)
    bpy.ops.wm.obj_export(
        filepath=combined_output,
        export_selected_objects=False,
        apply_modifiers=True,
        export_uv=True,
        export_normals=True,
        export_materials=True,
        export_pbr_extensions=True,
        export_triangulated_mesh=True,
        export_object_groups=True,
        export_material_groups=True,
        forward_axis="NEGATIVE_Z",
        up_axis="Y",
    )
    print(f"OPENDAO_TERRAIN_COMBINED output={combined_output}")
print(f"OPENDAO_TERRAIN_PARITY_PROBE output={output}")
