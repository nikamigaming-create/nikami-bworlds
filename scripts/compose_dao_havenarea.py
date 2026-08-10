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
from mathutils import Quaternion, Vector


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
    stage_actor = os.environ.get("DAO_OPENMW_STAGE_ACTOR", "").strip()
    if stage_actor:
        staged = 0
        only_stage_actor = os.environ.get("DAO_OPENMW_ONLY_STAGE_ACTOR", "") == "1"
        stage_position = [
            float(value) for value in os.environ["DAO_OPENMW_STAGE_POSITION"].split(",")
        ]
        stage_rotation = [
            float(value) for value in os.environ["DAO_OPENMW_STAGE_ROTATION"].split(",")
        ]
        for actor in area.get("actors", []):
            if actor.get("template", "").lower() == stage_actor.lower():
                actor["position"] = stage_position
                actor["rotation"] = stage_rotation
                actor["active"] = True
                staged += 1
            elif only_stage_actor:
                actor["active"] = False
        if staged != 1:
            raise RuntimeError(f"expected one stage actor {stage_actor!r}, found {staged}")
        print(f"DAO_OPENMW_STAGE_ACTOR template={stage_actor} position={stage_position} rotation={stage_rotation}")
    terrain_manifest = os.environ.get("DAO_TERRAIN_MATERIALS", "").strip()
    if terrain_manifest:
        descriptors = json.loads(Path(terrain_manifest).read_text(encoding="utf-8"))
        area.setdefault("terrain", {})["materials"] = [
            {"name": name, **descriptor} for name, descriptor in descriptors.items()
        ]
    if terrain_manifest or stage_actor:
        handle = tempfile.NamedTemporaryFile(
            mode="w", suffix=".havenarea", prefix="openmw-bake-",
            dir=area_path.parent, encoding="utf-8", delete=False
        )
        temporary_area = Path(handle.name)
        json.dump(area, handle)
        handle.close()
        import_area_path = temporary_area
        if terrain_manifest:
            print(f"DAO_OPENMW_TERRAIN_MANIFEST materials={len(descriptors)} path={terrain_manifest}")
    try:
        haven.import_havenarea(bpy.context, str(import_area_path), True, True, True)
    finally:
        if temporary_area is not None:
            temporary_area.unlink(missing_ok=True)

    # Godot replaces the imported actor root transform with the authored
    # stage transform. Haven's Blender importer instead multiplies that stage
    # quaternion by the GLB root/template quaternion, which reverses the
    # apparent three-quarter dialogue pose. Use Godot's transform semantics
    # for parity exports rather than compensating with hand-tuned yaw.
    if stage_actor and os.environ.get("DAO_OPENMW_GODOT_ACTOR_TRANSFORM", "") == "1":
        matched_roots = [
            obj for obj in bpy.context.scene.objects
            if str(obj.get("dao_template", "")).lower() == stage_actor.lower()
        ]
        if len(matched_roots) != 1:
            raise RuntimeError(
                f"expected one Godot-parity actor root {stage_actor!r}, found {len(matched_roots)}"
            )
        actor_root = matched_roots[0]
        actor_root.location = Vector(stage_position)
        actor_root.rotation_mode = "QUATERNION"
        actor_root.rotation_quaternion = Quaternion((
            stage_rotation[3], stage_rotation[0], stage_rotation[1], stage_rotation[2]
        ))
        print(
            f"DAO_OPENMW_GODOT_ACTOR_TRANSFORM root={actor_root.name} "
            f"rotation={stage_rotation}"
        )

    # Bake a real DAO idle pose into the static OpenMW interchange scene. The
    # GLBs carry Haven's exported armature/action and OBJ export evaluates the
    # armature modifiers at this frame, avoiding bind/T-pose actors.
    bpy.context.scene.frame_set(12)

    # Haven's current SpeedTree flattening is not yet trustworthy (some branch
    # buffers become long spikes). Keep authored architecture/setpieces and omit
    # only that broken conversion from the playable proof.
    trees_collection = bpy.data.collections.get("Trees")
    tree_objects = set(trees_collection.all_objects) if trees_collection else set()
    keep_trees = os.environ.get("DAO_OPENMW_KEEP_TREES", "") == "1"
    terrain_collection = bpy.data.collections.get("Terrain")
    terrain_objects = set(terrain_collection.all_objects) if terrain_collection else set()
    exclude_terrain = os.environ.get("DAO_OPENMW_EXCLUDE_TERRAIN", "") == "1"

    # The exterior proof keeps the visually approved Redcliffe encounter
    # neighborhood. Interior areas are already bounded authored rooms and must
    # remain complete, including their exported actor meshes.
    full_world = os.environ.get("DAO_OPENMW_FULL_WORLD", "") == "1"
    actor_only = os.environ.get("DAO_OPENMW_ACTOR_ONLY", "") == "1"
    environment_only = os.environ.get("DAO_OPENMW_ENVIRONMENT_ONLY", "") == "1"
    filter_redcliffe_exterior = area_path.stem.lower() == "lak100d" and not full_world
    cluster = Vector((
        float(os.environ.get("DAO_OPENMW_CLUSTER_X", "260.0")),
        float(os.environ.get("DAO_OPENMW_CLUSTER_Y", "301.0")),
        1.2,
    ))
    cluster_radius = float(os.environ.get("DAO_OPENMW_CLUSTER_RADIUS", "0"))
    remove_objects = []
    for obj in list(bpy.context.scene.objects):
        is_actor_mesh = obj.type == "MESH" and bool(re.match(r"^(?:E[FM]|D[FM]|H[FM])_", obj.name))
        if actor_only and obj.type == "MESH" and not is_actor_mesh:
            remove_objects.append(obj)
            continue
        if environment_only and is_actor_mesh:
            remove_objects.append(obj)
            continue
        if ((obj in tree_objects and not keep_trees)
                or (obj in terrain_objects and exclude_terrain)
                or obj.hide_render or obj.hide_get()):
            remove_objects.append(obj)
            continue
        if cluster_radius > 0.0 and obj.type == "MESH":
            # Cull against the transformed object bounds, not its origin.
            # Terrain patches and large camp setpieces often have an origin
            # outside the portrait cluster while their geometry covers it.
            corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
            nearest_x = min(max(cluster.x, min(c.x for c in corners)), max(c.x for c in corners))
            nearest_y = min(max(cluster.y, min(c.y for c in corners)), max(c.y for c in corners))
            if Vector((nearest_x - cluster.x, nearest_y - cluster.y)).length > cluster_radius:
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

    # DAO hair albedo is intentionally dark because the retail material adds
    # a character tint at runtime. Bake Marethari's authored silver tint into
    # the portable glTF payload so non-DAO material passes do not render it
    # black. Preserve texture detail and alpha rather than replacing the map.
    if os.environ.get("DAO_OPENMW_MARETHARI_HAIR", "") == "1":
        tinted_images = {}
        for obj in visible_meshes:
            if "_HAR_" not in obj.name:
                continue
            for slot in obj.material_slots:
                material = slot.material
                if material is None or not material.use_nodes:
                    continue
                normal_images = {
                    node.inputs["Color"].links[0].from_node.image
                    for node in material.node_tree.nodes
                    if node.type == "NORMAL_MAP" and node.inputs["Color"].is_linked
                    and node.inputs["Color"].links[0].from_node.type == "TEX_IMAGE"
                }
                source_node = next(
                    (node for node in material.node_tree.nodes
                     if node.type == "TEX_IMAGE" and node.image not in normal_images), None
                )
                source_image = source_node.image if source_node is not None else None
                if source_image is None:
                    continue
                if source_image.name not in tinted_images:
                    tinted = source_image.copy()
                    tinted.name = f"{source_image.name}_marethari_silver"
                    pixels = list(tinted.pixels)
                    for offset in range(0, len(pixels), 4):
                        luminance = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
                        value = min(1.0, 0.55 + luminance * 0.65)
                        pixels[offset] = value * 0.96
                        pixels[offset + 1] = value * 0.98
                        pixels[offset + 2] = value
                    tinted.pixels.foreach_set(pixels)
                    tinted_images[source_image.name] = tinted
                source_node.image = tinted_images[source_image.name]
        print(f"DAO_OPENMW_MARETHARI_HAIR images={len(tinted_images)}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_suffix = output_path.suffix.lower()
    if output_suffix not in {".obj", ".dae", ".glb", ".gltf"}:
        raise RuntimeError("OpenMW POC output must use .obj, .dae, .glb, or .gltf")

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
    if output_suffix in {".glb", ".gltf"}:
        # Keep the same native PBR payload used by the Godot oracle. Flattening
        # this scene through OBJ/MTL discards normal/roughness/alpha semantics
        # and makes an OpenMW-vs-Godot material comparison meaningless.
        bpy.ops.export_scene.gltf(
            filepath=str(output_path),
            export_format="GLB" if output_suffix == ".glb" else "GLTF_SEPARATE",
            use_selection=True,
            export_apply=True,
            export_yup=True,
            export_texcoords=True,
            export_normals=True,
            export_tangents=True,
            export_materials="EXPORT",
            export_cameras=False,
            export_lights=False,
            export_animations=False,
        )
    elif output_suffix == ".dae":
        bpy.ops.wm.collada_export(
            filepath=str(output_path),
            apply_modifiers=True,
            export_mesh_type=0,
            export_global_forward_selection="-Y",
            export_global_up_selection="Z",
            export_object_transformation_type_selection="matrix",
            export_animation_type_selection="sample",
            selected=True,
            include_children=True,
            include_armatures=True,
            include_shapekeys=True,
            include_animations=False,
            include_all_actions=False,
            active_uv_only=False,
            use_texture_copies=False,
            triangulate=True,
        )
    else:
        if bpy.app.version < (4, 0, 0):
            bpy.ops.export_scene.obj(
                filepath=str(output_path),
                check_existing=False,
                use_selection=True,
                use_mesh_modifiers=True,
                use_edges=False,
                use_normals=True,
                use_uvs=True,
                use_materials=True,
                use_triangles=True,
                use_blen_objects=True,
                group_by_object=True,
                group_by_material=True,
                keep_vertex_order=True,
                path_mode="RELATIVE",
                axis_forward="-Y",
                axis_up="Z",
            )
            # Haven's Blender importer stores DAO Z-up data as (x, z, -y).
            # Blender 3.6's legacy OBJ exporter does not honor the same axis
            # convention as its COLLADA exporter here. Convert both positions
            # and normals to the OpenMW adapter basis (x, -y, z).
            converted_path = output_path.with_suffix(".axis-converted.obj")
            with output_path.open("r", encoding="utf-8") as source, converted_path.open(
                "w", encoding="utf-8", newline="\n"
            ) as target:
                actor_object = False
                for line in source:
                    if line.startswith("o "):
                        object_name = line[2:].strip()
                        actor_object = bool(re.match(r"^(?:E[FM]|D[FM]|H[FM])_", object_name))
                        target.write(line)
                    elif line.startswith("v ") or line.startswith("vn "):
                        fields = line.split()
                        if actor_object:
                            target.write(
                                f"{fields[0]} {fields[1]} {-float(fields[2]):.6f} {fields[3]}\n"
                            )
                        else:
                            target.write(f"{fields[0]} {fields[1]} {fields[3]} {fields[2]}\n")
                    else:
                        target.write(line)
            converted_path.replace(output_path)
            print(f"DAO_OPENMW_OBJ_AXIS basis=(x,z,y) path={output_path}")
        else:
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
    if output_suffix == ".obj" and mtl_path.exists():
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
