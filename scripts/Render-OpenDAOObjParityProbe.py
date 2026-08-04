import math
import os
from pathlib import Path

import bpy
from mathutils import Vector


source = Path(os.environ["OPENDAO_OBJ_INPUT"])
output = Path(os.environ["OPENDAO_PROBE_OUTPUT"])
bpy.ops.wm.read_factory_settings(use_empty=True)
if source.suffix.lower() in {".glb", ".gltf"}:
    bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")
else:
    bpy.ops.wm.obj_import(filepath=str(source), forward_axis="NEGATIVE_Z", up_axis="Y")

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
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = str(output)
scene.world = bpy.data.worlds.new("ParityWorld")
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.12, 0.15, 0.20, 1.0)
scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.45
sun_data = bpy.data.lights.new("ParitySun", "SUN")
sun_data.energy = 2.4
sun_data.color = (1.0, 0.83, 0.62)
sun = bpy.data.objects.new("ParitySun", sun_data)
bpy.context.collection.objects.link(sun)
sun.rotation_euler = (math.radians(42.0), 0.0, math.radians(-55.0))
bpy.ops.render.render(write_still=True)
print(f"OPENDAO_OBJ_PARITY_PROBE output={output}")
