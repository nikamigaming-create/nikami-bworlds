"""Render a direct HavenArea preview with real UTC actors and no broken SpeedTree layer."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def main() -> int:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 3:
        raise SystemExit("expected: <havenarea_importer.py> <area.havenarea> <preview.png>")
    importer_path, area_path, output_path = map(Path, args)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    spec = importlib.util.spec_from_file_location("havenarea_importer", importer_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load Haven importer: {importer_path}")
    haven = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(haven)
    haven.import_havenarea(bpy.context, str(area_path), True, True, True)

    # Haven's current SpeedTree conversion emits stretched billboard geometry.
    # It is a separate known layer, so omit it from this actor/setpiece proof.
    trees = bpy.data.collections.get("Trees")
    tree_objects = set(trees.all_objects) if trees else set()

    # Keep the authored village/actor neighborhood and cull only distant
    # backdrop geometry so Eevee can render the POC reliably.
    cluster = Vector((260.0, 301.0, 1.2))
    remove_objects = []
    for obj in list(bpy.context.scene.objects):
        if obj in tree_objects or obj.hide_render or obj.hide_get():
            remove_objects.append(obj)
            continue
        if obj.type == "MESH":
            center = obj.matrix_world.translation
            if Vector((center.x - cluster.x, center.y - cluster.y)).length > 85.0:
                remove_objects.append(obj)
    for obj in remove_objects:
        bpy.data.objects.remove(obj, do_unlink=True)
    for _ in range(3):
        bpy.ops.outliner.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)

    camera_data = bpy.data.cameras.new("Redcliffe actor cluster")
    camera = bpy.data.objects.new("Redcliffe actor cluster", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = Vector((255.0, 316.0, 4.5))
    target = Vector((260.0, 300.0, 1.35))
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 50
    camera.data.clip_start = 0.1
    camera.data.clip_end = 5000

    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.image_settings.color_mode = "RGBA"
    if scene.world is None:
        scene.world = bpy.data.worlds.new("DAO World")
    scene.world.color = (0.025, 0.045, 0.075)
    sun_data = bpy.data.lights.new("DAO Sun", "SUN")
    sun_data.energy = 2.4
    sun_data.color = (1.0, 0.74, 0.52)
    sun = bpy.data.objects.new("DAO Sun", sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (0.65, -0.35, -0.8)
    fill_data = bpy.data.lights.new("DAO Sky Fill", "AREA")
    fill_data.energy = 900
    fill_data.shape = "DISK"
    fill_data.size = 18
    fill_data.color = (0.45, 0.62, 1.0)
    fill = bpy.data.objects.new("DAO Sky Fill", fill_data)
    bpy.context.collection.objects.link(fill)
    fill.location = Vector((255.0, 292.0, 14.0))
    fill.rotation_euler = ((cluster - fill.location).to_track_quat("-Z", "Y").to_euler())
    scene.frame_set(12)
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)

    actors = bpy.data.collections.get("Actors")
    actor_roots = [obj for obj in actors.all_objects if obj.name.startswith("Actor_")] if actors else []
    print(f"DAO_HAVENAREA_PREVIEW actors={len(actor_roots)} output={output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
