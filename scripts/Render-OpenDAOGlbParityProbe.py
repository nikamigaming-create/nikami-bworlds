import math
import os
from pathlib import Path

import bpy
from mathutils import Vector


inputs = [Path(value) for value in os.environ["OPENDAO_GLB_INPUTS"].split(";") if value]
output = Path(os.environ["OPENDAO_PROBE_OUTPUT"])

bpy.ops.wm.read_factory_settings(use_empty=True)
for source in inputs:
    bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")

camera_data = bpy.data.cameras.new("ParityCamera")
camera = bpy.data.objects.new("ParityCamera", camera_data)
bpy.context.collection.objects.link(camera)
camera.location = Vector((250.0, 307.0, 4.65))
target = Vector((260.0, 300.0, 2.5))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.angle = math.radians(72.0)
camera_data.clip_start = 0.05
camera_data.clip_end = 4000.0

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
output.parent.mkdir(parents=True, exist_ok=True)
scene.render.filepath = str(output)
scene.world = bpy.data.worlds.new("ParityWorld")
scene.world.color = (0.12, 0.14, 0.16)
bpy.ops.render.render(write_still=True)
print(f"OPENDAO_GLB_PARITY_PROBE inputs={len(inputs)} output={output}")
