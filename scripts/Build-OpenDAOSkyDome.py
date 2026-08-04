import os

import bpy


target = os.environ["OPENDAO_SKY_OBJ_OUTPUT"]
texture_path = os.environ["OPENDAO_SKY_TEXTURE"]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_uv_sphere_add(
    segments=128,
    ring_count=64,
    radius=600.0,
    location=(260.0, 300.0, 0.0),
)
sky = bpy.context.object
sky.name = "OpenDAO_AtmosphereCloudDome"
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.flip_normals()
bpy.ops.object.mode_set(mode="OBJECT")

material = bpy.data.materials.new("OpenDAO_AtmosphereClouds")
material.use_nodes = True
nodes = material.node_tree.nodes
links = material.node_tree.links
principled = nodes.get("Principled BSDF")
image_node = nodes.new("ShaderNodeTexImage")
image_node.image = bpy.data.images.load(texture_path)
links.new(image_node.outputs["Color"], principled.inputs["Base Color"])
principled.inputs["Roughness"].default_value = 1.0
sky.data.materials.append(material)

bpy.ops.wm.obj_export(
    filepath=target,
    export_selected_objects=False,
    apply_modifiers=True,
    export_uv=True,
    export_normals=True,
    export_materials=True,
    export_pbr_extensions=True,
    export_triangulated_mesh=True,
    forward_axis="NEGATIVE_Z",
    up_axis="Y",
)
