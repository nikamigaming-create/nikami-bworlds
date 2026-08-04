import argparse
import os

import bpy


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default=os.environ.get("OPENDAO_GLB_INPUT"))
    parser.add_argument("--output", default=os.environ.get("OPENDAO_DAE_OUTPUT"))
    args, _ = parser.parse_known_args()
    if not args.input or not args.output:
        parser.error("--input/--output or OPENDAO_GLB_INPUT/OPENDAO_DAE_OUTPUT are required")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.input, import_shading="NORMALS")
    bpy.ops.wm.collada_export(
        filepath=args.output,
        apply_modifiers=True,
        export_mesh_type=0,
        export_global_forward_selection="-Z",
        export_global_up_selection="Y",
        export_object_transformation_type_selection="MATRIX",
        export_animation_type_selection="SAMPLE",
        selected=False,
        include_children=True,
        include_armatures=True,
        include_shapekeys=True,
        include_animations=False,
        include_all_actions=False,
        active_uv_only=False,
        use_texture_copies=True,
        triangulate=True,
    )


if __name__ == "__main__":
    main()
