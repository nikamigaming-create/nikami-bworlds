import os

import bpy


source = os.environ["OPENDAO_GLB_INPUT"]
target = os.environ["OPENDAO_OBJ_OUTPUT"]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=source, import_shading="NORMALS")
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
