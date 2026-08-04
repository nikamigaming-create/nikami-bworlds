"""Compose a Haven Tools .havenarea export and write one OpenMW-readable OBJ.

Run with Blender, not CPython:
  blender --background --python compose_dao_havenarea.py -- <importer.py> <area> <out.obj>
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tempfile
from pathlib import Path

import bpy
from mathutils import Vector


def main() -> int:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 3:
        raise SystemExit("expected: <havenarea_importer.py> <area.havenarea> <output.obj>")

    importer_path, area_path, output_path = map(Path, args)
    spec = importlib.util.spec_from_file_location("havenarea_importer", importer_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load Haven importer: {importer_path}")
    haven = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(haven)

    area = json.loads(area_path.read_text(encoding="utf-8"))
    import_area_path = area_path
    temporary_area = None
    terrain_manifest = os.environ.get("DAO_TERRAIN_MATERIALS", "").strip()
    if terrain_manifest:
        descriptors = json.loads(Path(terrain_manifest).read_text(encoding="utf-8"))
        area.setdefault("terrain", {})["materials"] = [
            {"name": name, **descriptor} for name, descriptor in descriptors.items()
        ]
        handle = tempfile.NamedTemporaryFile(
            mode="w", suffix=".havenarea", prefix="openmw-bake-",
            dir=area_path.parent, encoding="utf-8", delete=False
        )
        temporary_area = Path(handle.name)
        json.dump(area, handle)
        handle.close()
        import_area_path = temporary_area
        print(f"DAO_OPENMW_TERRAIN_MANIFEST materials={len(descriptors)} path={terrain_manifest}")
    try:
        haven.import_havenarea(bpy.context, str(import_area_path), True, True, True)
    finally:
        if temporary_area is not None:
            temporary_area.unlink(missing_ok=True)

    # Bake a real DAO idle pose into the static OpenMW interchange scene. The
    # GLBs carry Haven's exported armature/action and OBJ export evaluates the
    # armature modifiers at this frame, avoiding bind/T-pose actors.
    bpy.context.scene.frame_set(12)

    # Haven's current SpeedTree flattening is not yet trustworthy (some branch
    # buffers become long spikes). Keep authored architecture/setpieces and omit
    # only that broken conversion from the playable proof.
    trees_collection = bpy.data.collections.get("Trees")
    tree_objects = set(trees_collection.all_objects) if trees_collection else set()

    # The exterior proof keeps the visually approved Redcliffe encounter
    # neighborhood. Interior areas are already bounded authored rooms and must
    # remain complete, including their exported actor meshes.
    full_world = os.environ.get("DAO_OPENMW_FULL_WORLD", "") == "1"
    filter_redcliffe_exterior = area_path.stem.lower() == "lak100d" and not full_world
    cluster = Vector((260.0, 301.0, 1.2))
    remove_objects = []
    for obj in list(bpy.context.scene.objects):
        if obj in tree_objects or obj.hide_render or obj.hide_get():
            remove_objects.append(obj)
            continue
        if filter_redcliffe_exterior and obj.type == "MESH":
            center = obj.matrix_world.translation
            if Vector((center.x - cluster.x, center.y - cluster.y)).length > 85.0:
                remove_objects.append(obj)
    for obj in remove_objects:
        bpy.data.objects.remove(obj, do_unlink=True)
    for _ in range(3):
        bpy.ops.outliner.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)

    # OpenMW's interior proof cell has no usable sky or ocean. Package the
    # authored Redcliffe panorama and a conservative sea-level surface into
    # the interchange scene so the exterior remains self-contained.
    sky_path = os.environ.get("DAO_SKY_PANORAMA", "").strip()
    if sky_path:
        bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=800.0, location=(260.0, 300.0, 0.0))
        sky = bpy.context.object
        sky.name = "OpenDAO_Redcliffe_Sky"
        sky.rotation_euler.z = 2.26892802759  # authored 130-degree orientation
        bpy.context.view_layer.objects.active = sky
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.flip_normals()
        bpy.ops.object.mode_set(mode='OBJECT')
        sky_material = bpy.data.materials.new("OpenDAO_Redcliffe_Sky")
        sky_material.use_nodes = True
        sky_nodes = sky_material.node_tree.nodes
        sky_links = sky_material.node_tree.links
        sky_bsdf = next(node for node in sky_nodes if node.type == 'BSDF_PRINCIPLED')
        sky_image_node = sky_nodes.new('ShaderNodeTexImage')
        sky_image_node.image = bpy.data.images.load(sky_path, check_existing=True)
        sky_links.new(sky_image_node.outputs['Color'], sky_bsdf.inputs['Base Color'])
        sky_bsdf.inputs['Roughness'].default_value = 1.0
        sky.data.materials.append(sky_material)

    if os.environ.get("DAO_OPENMW_OCEAN", "") == "1":
        bpy.ops.mesh.primitive_grid_add(x_subdivisions=65, y_subdivisions=65, size=2000.0, location=(260.0, 300.0, -0.05))
        ocean = bpy.context.object
        ocean.name = "OpenDAO_Redcliffe_Ocean"
        ocean_material = bpy.data.materials.new("OpenDAO_Redcliffe_Ocean")
        ocean_material.diffuse_color = (0.025, 0.16, 0.22, 1.0)
        ocean_material.use_nodes = True
        ocean_bsdf = next(node for node in ocean_material.node_tree.nodes if node.type == 'BSDF_PRINCIPLED')
        ocean_bsdf.inputs['Base Color'].default_value = (0.025, 0.16, 0.22, 1.0)
        ocean_bsdf.inputs['Roughness'].default_value = 0.18
        ocean_bsdf.inputs['Metallic'].default_value = 0.0
        ocean.data.materials.append(ocean_material)

    mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    visible_meshes = [obj for obj in mesh_objects if not obj.hide_render]
    if not visible_meshes:
        raise RuntimeError("Haven import produced no visible mesh objects")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.suffix.lower() != ".obj":
        raise RuntimeError("Blender 5.2 POC output must use .obj")

    # GLB images are packed in Blender. OBJ/MTL cannot reference packed data, so
    # material maps must be written beside the interchange scene and rebound to
    # real relative paths before export.
    texture_dir = output_path.parent / f"{output_path.stem}-textures"
    texture_dir.mkdir(parents=True, exist_ok=True)

    # OBJ cannot represent DAO's palette/mask shader. Bake each terrain
    # material to one conventional opaque diffuse image before OBJ export.
    if terrain_manifest:
        bpy.context.scene.render.engine = 'CYCLES'
        bpy.context.scene.cycles.device = 'CPU'
        baked_materials = set()
        for obj in visible_meshes:
            if not any(collection.name == "Terrain" for collection in obj.users_collection):
                continue
            for slot in obj.material_slots:
                material = slot.material
                if material is None or material.name in baked_materials or not material.use_nodes:
                    continue
                baked_materials.add(material.name)
                image_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", material.name).strip("._") or "terrain"
                baked = bpy.data.images.new(f"{image_name}_openmw_baked", width=1024, height=1024, alpha=False)
                baked.filepath_raw = str(texture_dir / f"{image_name}_openmw_baked.png")
                baked.file_format = 'PNG'
                target = material.node_tree.nodes.new('ShaderNodeTexImage')
                target.image = baked
                material.node_tree.nodes.active = target
                bpy.ops.object.select_all(action='DESELECT')
                obj.hide_set(False)
                obj.select_set(True)
                bpy.context.view_layer.objects.active = obj
                bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, margin=8, use_clear=True)
                baked.save()
                nodes = material.node_tree.nodes
                links = material.node_tree.links
                nodes.clear()
                output = nodes.new('ShaderNodeOutputMaterial')
                principled = nodes.new('ShaderNodeBsdfPrincipled')
                diffuse = nodes.new('ShaderNodeTexImage')
                diffuse.image = baked
                links.new(diffuse.outputs['Color'], principled.inputs['Base Color'])
                links.new(principled.outputs['BSDF'], output.inputs['Surface'])
                principled.inputs['Roughness'].default_value = 0.72
                principled.inputs['Metallic'].default_value = 0.0
                print(f"DAO_OPENMW_TERRAIN_BAKE material={material.name} image={baked.filepath_raw}")
    used_names: set[str] = set()
    saved_images = 0
    for index, image in enumerate(bpy.data.images):
        if image.name in {"Render Result", "Viewer Node"}:
            continue
        stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", image.name).strip("._") or f"image_{index}"
        candidate = f"{stem}.png"
        suffix = 1
        while candidate.lower() in used_names:
            candidate = f"{stem}_{suffix}.png"
            suffix += 1
        used_names.add(candidate.lower())
        try:
            # Force lazy FILE/GLB payloads to decode before rebinding their
            # path to the portable export directory.
            _ = image.pixels[0]
            image.filepath_raw = str(texture_dir / candidate)
            image.file_format = "PNG"
            image.save()
            saved_images += 1
        except (RuntimeError, IndexError) as exc:
            print(f"DAO_OPENMW_IMAGE_SKIP name={image.name!r} source={image.source} error={exc}")
    print(f"DAO_OPENMW_IMAGES saved={saved_images} total={len(bpy.data.images)} dir={texture_dir}")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in visible_meshes:
        obj.hide_set(False)
        obj.select_set(True)
    bpy.context.view_layer.objects.active = visible_meshes[0]
    bpy.ops.wm.obj_export(
        filepath=str(output_path),
        check_existing=False,
        apply_modifiers=True,
        apply_transform=True,
        export_selected_objects=True,
        export_uv=True,
        export_normals=True,
        export_materials=True,
        export_pbr_extensions=False,
        path_mode="RELATIVE",
        export_triangulated_mesh=True,
        export_object_groups=True,
        export_material_groups=True,
    )

    # Blender 5.2's Windows OBJ exporter can serialize packed-image names as
    # synthetic C:/Image_*.png paths even after the images have been saved.
    # Point those MTL references at the real portable texture directory.
    mtl_path = output_path.with_suffix(".mtl")
    if mtl_path.exists():
        mtl_text = mtl_path.read_text(encoding="utf-8")
        mtl_text = re.sub(
            r"C:/([^/\s]+\.png)",
            lambda match: f"{texture_dir.name}/{match.group(1)}",
            mtl_text,
        )
        # OSG's OBJ reader used by OpenMW does not consume the optional -bm
        # argument and otherwise folds it into the texture filename.
        mtl_text = re.sub(r"(?m)^(map_Bump)\s+-bm\s+\S+\s+", r"\1 ", mtl_text)
        mtl_path.write_text(mtl_text, encoding="utf-8", newline="\n")

    summary = {
        "source": str(area_path),
        "output": str(output_path),
        "meshObjects": len(mesh_objects),
        "visibleMeshObjects": len(visible_meshes),
        "terrainKinds": len(area.get("terrain", {}).get("patches", {})),
        "propKinds": len(area.get("props", {})),
        "treeKinds": len(area.get("trees", {})),
        "actors": len(area.get("actors", [])),
        "activeActors": sum(bool(actor.get("active")) for actor in area.get("actors", [])),
    }
    print("DAO_OPENMW_COMPOSE " + json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
