import os
import math

import bpy
from mathutils import Vector


source = os.environ["OPENDAO_OBJ_INPUT"]
target = os.environ["OPENDAO_OBJ_OUTPUT"]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(
    filepath=source,
    forward_axis="NEGATIVE_Z",
    up_axis="Y",
    use_split_objects=True,
    use_split_groups=True,
)
for obj in list(bpy.data.objects):
    if obj.type != "MESH" or not obj.name.upper().startswith("HM_"):
        bpy.data.objects.remove(obj, do_unlink=True)
print(f"OPENDAO_ACTOR_OBJECTS count={len(bpy.context.scene.objects)}")

# The DAO-to-OpenMW axis conversion changes handedness. Rotate each placed
# actor around its own XY pivot; rotating the combined scene would move actors.
clusters: list[dict] = []
for obj in bpy.context.scene.objects:
    corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    center = sum(corners, Vector()) / 8.0
    cluster = next(
        (item for item in clusters if (Vector((item["x"], item["y"])) - Vector((center.x, center.y))).length < 0.75),
        None,
    )
    if cluster is None:
        cluster = {"x": center.x, "y": center.y, "objects": []}
        clusters.append(cluster)
    cluster["objects"].append(obj)

hair_colors = [
    (0.08, 0.045, 0.025, 1.0),
    (0.16, 0.08, 0.035, 1.0),
    (0.035, 0.028, 0.022, 1.0),
    (0.28, 0.16, 0.07, 1.0),
]
for cluster_index, cluster in enumerate(clusters):
    pivot = Vector((cluster["x"], cluster["y"], 0.0))
    for obj in cluster["objects"]:
        inverse = obj.matrix_world.inverted()
        for vertex in obj.data.vertices:
            world = obj.matrix_world @ vertex.co
            world.x = 2.0 * pivot.x - world.x
            world.y = 2.0 * pivot.y - world.y
            vertex.co = inverse @ world
        if "_HAR_" in obj.name.upper():
            for slot in obj.material_slots:
                if slot.material is None:
                    continue
                slot.material = slot.material.copy()
                slot.material.diffuse_color = hair_colors[cluster_index % len(hair_colors)]
print(f"OPENDAO_ACTOR_CLUSTERS count={len(clusters)} rotation_degrees={math.degrees(math.pi):.0f}")
bpy.ops.wm.obj_export(
    filepath=target,
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
