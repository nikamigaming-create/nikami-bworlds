"""Render one intact UTC-derived Haven actor GLB."""

from __future__ import annotations

import sys
from pathlib import Path

import bpy
from mathutils import Vector


def main() -> int:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 2:
        raise SystemExit("expected: <actor.glb> <preview.png>")
    actor_path, output_path = map(Path, args)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(actor_path))
    bpy.context.view_layer.update()
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("actor GLB contains no meshes")

    corners = [obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    center = (minimum + maximum) * 0.5
    height = max(1.0, maximum.z - minimum.z)

    camera_data = bpy.data.cameras.new("UTC actor camera")
    camera = bpy.data.objects.new("UTC actor camera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = center + Vector((height * 0.35, height * 2.4, height * 0.12))
    target = Vector((center.x, center.y, minimum.z + height * 0.52))
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 72
    camera.data.clip_start = 0.01
    camera.data.clip_end = 1000

    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.studio_light = "paint.sl"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = "WORLD"
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.055, 0.075, 0.105)
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 1200
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)
    print(f"DAO_ACTOR_PREVIEW meshes={len(meshes)} output={output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
