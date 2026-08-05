import os
import math
from pathlib import Path

import bpy
from mathutils import Matrix


source = Path(os.environ["OPENDAO_GLB_INPUT"])
target = Path(os.environ["OPENDAO_GLB_OUTPUT"])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")

mesh_count = 0
for obj in list(bpy.context.scene.objects):
    if obj.type != "MESH":
        continue
    world = obj.matrix_world.copy()
    obj.data = obj.data.copy()
    # OpenMW's legacy glTF reader converts node transforms from glTF Y-up but
    # consumes POSITION/NORMAL arrays as Z-up. Counter-rotate mesh data before
    # Blender's standards-compliant glTF export so the raw arrays arrive Z-up.
    z_up_counter_rotation = Matrix.Rotation(math.radians(90.0), 4, "X")
    obj.data.transform(z_up_counter_rotation @ world.to_3x3().to_4x4())
    location = world.translation.copy()
    obj.parent = None
    obj.matrix_world = Matrix.Translation(location)
    mesh_count += 1

for obj in list(bpy.context.scene.objects):
    if obj.type == "EMPTY" and not obj.children:
        bpy.data.objects.remove(obj, do_unlink=True)

target.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=str(target),
    export_format="GLB",
    use_active_scene=True,
    export_animations=False,
    export_skins=False,
)
print(f"OPENDAO_GLTF_BAKED_TRANSFORMS meshes={mesh_count} output={target}")
