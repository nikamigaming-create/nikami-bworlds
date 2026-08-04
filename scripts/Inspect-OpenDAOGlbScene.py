import os

import bpy
from mathutils import Vector


source = os.environ["OPENDAO_GLB_INPUT"]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=source, import_shading="NORMALS")

depsgraph = bpy.context.evaluated_depsgraph_get()
mins = Vector((float("inf"),) * 3)
maxs = Vector((float("-inf"),) * 3)
nearby = []
probe = Vector((250.0, 307.0, 4.65))
for obj in bpy.context.scene.objects:
    if obj.type != "MESH":
        continue
    corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    for corner in corners:
        mins.x = min(mins.x, corner.x)
        mins.y = min(mins.y, corner.y)
        mins.z = min(mins.z, corner.z)
        maxs.x = max(maxs.x, corner.x)
        maxs.y = max(maxs.y, corner.y)
        maxs.z = max(maxs.z, corner.z)
    center = sum(corners, Vector()) / 8.0
    distance = (center - probe).length
    if distance < 40.0:
        material_names = tuple(slot.material.name for slot in obj.material_slots if slot.material)
        nearby.append((distance, obj.name, tuple(round(v, 4) for v in center), material_names))

print("SCENE_BOUNDS", tuple(mins), tuple(maxs))
for material in bpy.data.materials:
    if material.name.lower().startswith("lak100d_") and material.use_nodes:
        images = [node.image.name for node in material.node_tree.nodes if node.type == "TEX_IMAGE" and node.image]
        print("TERRAIN_MATERIAL", material.name, images)
for item in sorted(nearby)[:30]:
    print("NEAR", item)
near_materials = {name for item in nearby for name in item[3]}
for material in sorted((m for m in bpy.data.materials if m.name in near_materials), key=lambda m: m.name):
    images = []
    if material.use_nodes:
        for node in material.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image:
                images.append((node.name, node.image.name, node.image.filepath))
    print("NEAR_MATERIAL", material.name, images)
for x, y in ((250.0, 307.0), (250.0, -307.0), (257.5, 302.2), (260.0, 300.0)):
    hit, location, normal, _face, obj, _matrix = bpy.context.scene.ray_cast(
        depsgraph, Vector((x, y, 200.0)), Vector((0.0, 0.0, -1.0)), distance=500.0
    )
    print("RAY", x, y, hit, tuple(location), tuple(normal), obj.name if obj else None)
