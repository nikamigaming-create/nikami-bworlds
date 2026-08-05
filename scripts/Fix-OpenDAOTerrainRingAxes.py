import math
import os
from pathlib import Path

import bpy
from mathutils import Matrix


source = Path(os.environ["OPENDAO_GLB_INPUT"])
target = Path(os.environ["OPENDAO_GLB_OUTPUT"])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")

# The old ring builder preserved each terrain tile's Y-up mesh arrays inside
# Blender's Z-up scene. Rotate mesh-local data only; keeping every object and
# parent transform intact preserves the placements from the Haven area table.
rotation = Matrix.Rotation(math.radians(-90.0), 4, "X")
mesh_count = 0
for obj in bpy.context.scene.objects:
    if obj.type != "MESH":
        continue
    obj.data = obj.data.copy()
    obj.data.transform(rotation)
    mesh_count += 1

target.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=str(target),
    export_format="GLB",
    use_active_scene=True,
    export_animations=False,
    export_skins=False,
)
print(f"OPENDAO_TERRAIN_RING_AXIS_FIX meshes={mesh_count} output={target}")
