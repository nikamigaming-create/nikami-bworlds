import os
from pathlib import Path

import bpy


source = Path(os.environ["OPENDAO_TERRAIN_RING_INPUT"])
target = Path(os.environ["OPENDAO_TERRAIN_RING_OUTPUT"])
excluded = tuple(
    value.strip().lower()
    for value in os.environ.get("OPENDAO_TERRAIN_RING_EXCLUDE", "").split(",")
    if value.strip()
)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")

removed = []
for obj in list(bpy.context.scene.objects):
    if any(token in obj.name.lower() for token in excluded):
        removed.append(obj.name)
        bpy.data.objects.remove(obj, do_unlink=True)

target.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=str(target),
    export_format="GLB",
    use_active_scene=True,
    export_animations=False,
    export_skins=False,
)
print(f"OPENDAO_TERRAIN_FILTER removed={len(removed)} output={target}")
