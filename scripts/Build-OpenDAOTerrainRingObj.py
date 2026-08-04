import json
import os
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
target = Path(os.environ["OPENDAO_OBJ_OUTPUT"])
terrain_baked_dir_value = os.environ.get("OPENDAO_TERRAIN_BAKED_DIR", "")
terrain_baked_dir = Path(terrain_baked_dir_value) if terrain_baked_dir_value else None
area = json.loads(area_path.read_text(encoding="utf-8"))
cluster = Vector((260.0, 301.0))

bpy.ops.wm.read_factory_settings(use_empty=True)
instances = []
placement_count = 0
loaded_definitions = 0
for definition in area.get("terrain", {}).get("patches", {}).values():
    selected = []
    for record in definition.get("instances", []):
        position = record["position"]
        if (Vector((position[0], position[1])) - cluster).length > 85.0:
            selected.append(record)
    if not selected:
        continue
    loaded_definitions += 1
    placement_count += len(selected)

    model_path = root / definition["file"]
    if not model_path.is_file():
        print(f"OPENDAO_TERRAIN_RING missing={model_path}")
        continue
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(model_path), import_shading="NORMALS")
    prototypes = [obj for obj in bpy.context.scene.objects if obj not in before and obj.type == "MESH"]
    for record in selected:
        p = record["position"]
        q = record.get("rotation", [0.0, 0.0, 0.0, 1.0])
        scale = float(record.get("scale", 1.0))
        placement = (
            Matrix.Translation(Vector((p[0], p[1], p[2])))
            @ Quaternion((q[3], q[0], q[1], q[2])).to_matrix().to_4x4()
            @ Matrix.Scale(scale, 4)
        )
        for prototype in prototypes:
            duplicate = prototype.copy()
            duplicate.data = prototype.data
            duplicate.matrix_world = placement @ prototype.matrix_world
            bpy.context.collection.objects.link(duplicate)
            instances.append(duplicate)
    for prototype in prototypes:
        bpy.data.objects.remove(prototype, do_unlink=True)

target.parent.mkdir(parents=True, exist_ok=True)
if target.suffix.lower() in (".glb", ".gltf"):
    if terrain_baked_dir is None:
        raise RuntimeError("OPENDAO_TERRAIN_BAKED_DIR is required for native terrain glTF")
    replaced = 0
    for material in bpy.data.materials:
        key = next(
            (name for name in area.get("terrain", {}).get("patches", {}).keys() if name.lower() in material.name.lower()),
            None,
        )
        if key is None:
            continue
        material_key = key if key.lower().endswith(".mao") else f"{key}.mao"
        image_path = terrain_baked_dir / f"{material_key}_openmw_baked_4k.png"
        if not image_path.is_file():
            raise RuntimeError(f"missing resolved terrain texture: {image_path}")
        image = bpy.data.images.load(str(image_path), check_existing=True)
        material.use_nodes = True
        nodes = material.node_tree.nodes
        links = material.node_tree.links
        nodes.clear()
        output = nodes.new("ShaderNodeOutputMaterial")
        principled = nodes.new("ShaderNodeBsdfPrincipled")
        diffuse = nodes.new("ShaderNodeTexImage")
        diffuse.image = image
        links.new(diffuse.outputs["Color"], principled.inputs["Base Color"])
        links.new(principled.outputs["BSDF"], output.inputs["Surface"])
        principled.inputs["Metallic"].default_value = 0.0
        principled.inputs["Roughness"].default_value = 0.72
        replaced += 1
    bpy.ops.export_scene.gltf(
        filepath=str(target),
        export_format="GLB" if target.suffix.lower() == ".glb" else "GLTF_SEPARATE",
        use_active_scene=True,
        export_animations=False,
        export_skins=False,
    )
    print(f"OPENDAO_TERRAIN_RING_GLTF materials={replaced}")
else:
    bpy.ops.wm.obj_export(
        filepath=str(target),
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
target.with_suffix(".manifest.json").write_text(
    json.dumps(
        {
            "layer": "connected_terrain",
            "definitions": loaded_definitions,
            "placements": placement_count,
            "mesh_instances": len(instances),
            "inner_radius": 85.0,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
print(f"OPENDAO_TERRAIN_RING instances={len(instances)} output={target}")
