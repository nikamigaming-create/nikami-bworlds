"""Render a deterministic preview of the composed DAO/OpenMW OBJ with Blender."""

from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def point_camera(camera: bpy.types.Object, target: Vector) -> None:
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()


def main() -> int:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 2:
        raise SystemExit("expected: <scene.obj> <preview.png>")

    scene_path, output_path = map(Path, args)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.obj_import(filepath=str(scene_path), forward_axis="NEGATIVE_Z", up_axis="Y")

    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("OBJ import produced no meshes")

    corners = [obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    center = (minimum + maximum) * 0.5
    span = maximum - minimum

    camera_data = bpy.data.cameras.new("Redcliffe overview")
    camera = bpy.data.objects.new("Redcliffe overview", camera_data)
    bpy.context.collection.objects.link(camera)
    # Redcliffe's live gameplay/actor cluster occupies this authored region.
    # Framing it explicitly prevents distant backdrop and water planes from
    # dominating an automatic whole-level fit.
    target = Vector((300.0, 340.0, 24.0))
    camera.location = Vector((570.0, 45.0, 255.0))
    camera.data.lens = 48
    camera.data.sensor_width = 36
    camera.data.clip_start = 0.1
    camera.data.clip_end = 10000.0
    point_camera(camera, target)
    bpy.context.scene.camera = camera

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.studio_light = "paint.sl"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = "WORLD"
    scene.display.shading.curvature_ridge_factor = 1.8
    scene.display.shading.curvature_valley_factor = 1.2
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.055, 0.075, 0.105)
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.filepath = str(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)
    print(
        "DAO_PREVIEW "
        f"meshes={len(meshes)} boundsMin={tuple(round(x, 3) for x in minimum)} "
        f"boundsMax={tuple(round(x, 3) for x in maximum)} output={output_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
