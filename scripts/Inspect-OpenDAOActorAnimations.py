"""Print Blender animation bindings for one Haven actor GLB.

Run with Blender in background mode and set OPENDAO_ACTOR_MODEL to the GLB.
This is intentionally read-only; it exists to make actor-pose baking auditable.
"""

import os

import bpy


model = os.environ["OPENDAO_ACTOR_MODEL"]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=model, import_shading="NORMALS")

scene = bpy.context.scene
print(
    "OPENDAO_SCENE_TIMING",
    f"fps={scene.render.fps}",
    f"fps_base={scene.render.fps_base}",
    f"frame_start={scene.frame_start}",
    f"frame_end={scene.frame_end}",
)
for action in bpy.data.actions:
    print(
        "OPENDAO_ACTION",
        f"name={action.name}",
        f"frame_range={tuple(action.frame_range)}",
        f"slots={len(getattr(action, 'slots', []))}",
    )
for obj in bpy.context.scene.objects:
    animation = obj.animation_data
    if obj.type == "ARMATURE" or animation is not None:
        print(
            "OPENDAO_BINDING",
            f"name={obj.name}",
            f"type={obj.type}",
            f"action={animation.action.name if animation and animation.action else ''}",
        )
        if obj.type == "ARMATURE":
            seconds = float(os.environ.get("OPENDAO_ACTOR_SECONDS", "0"))
            exact_frame = seconds * scene.render.fps / scene.render.fps_base
            frame = int(exact_frame)
            scene.frame_set(frame, subframe=exact_frame - frame)
            bpy.context.view_layer.update()
            print("OPENDAO_ARMATURE_WORLD", [list(row) for row in obj.matrix_world])
            for bone_name in ("Root", "Chest2", "Neck", "Neck1", "Head"):
                bone = obj.pose.bones.get(bone_name)
                if bone is not None:
                    world = obj.matrix_world @ bone.matrix
                    print(
                        "OPENDAO_BONE_WORLD",
                        f"name={bone_name}",
                        [list(row) for row in world],
                    )
