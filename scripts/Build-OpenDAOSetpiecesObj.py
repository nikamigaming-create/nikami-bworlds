import json
import os
import re
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
target = Path(os.environ["OPENDAO_OBJ_OUTPUT"])
area = json.loads(area_path.read_text(encoding="utf-8"))
cluster = Vector((260.0, 301.0))

bpy.ops.wm.read_factory_settings(use_empty=True)
instances = []
prototype_count = 0
placement_count = 0
loaded_definitions = 0
for key, definition in area.get("props", {}).items():
    lower = key.lower()
    if lower.startswith("plc_") or lower.startswith("hro_") or "water" in lower:
        continue
    selected = []
    seen = set()
    for record in definition.get("instances", []):
        position = record["position"]
        distance = (Vector((position[0], position[1])) - cluster).length
        rotation = tuple(record.get("rotation", [0.0, 0.0, 0.0, 1.0]))
        transform_key = tuple(round(float(value), 4) for value in position) + tuple(
            round(float(value), 4) for value in rotation
        )
        if distance <= 85.0 or distance > 190.0 or transform_key in seen:
            continue
        seen.add(transform_key)
        selected.append(record)
    if not selected:
        continue

    model_path = root / definition["file"]
    if not model_path.is_file():
        print(f"OPENDAO_SETPIECES missing={model_path}")
        continue
    loaded_definitions += 1
    placement_count += len(selected)
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(model_path), import_shading="NORMALS")
    prototypes = [obj for obj in bpy.context.scene.objects if obj not in before and obj.type == "MESH"]
    prototype_count += len(prototypes)
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

texture_dir = target.parent / f"{target.stem}-textures"
texture_dir.mkdir(parents=True, exist_ok=True)
used = set()
for index, image in enumerate(bpy.data.images):
    if image.name in {"Render Result", "Viewer Node"}:
        continue
    stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", image.name).strip("._") or f"image_{index}"
    name = f"{stem}.png"
    suffix = 1
    while name.lower() in used:
        name = f"{stem}_{suffix}.png"
        suffix += 1
    used.add(name.lower())
    try:
        _ = image.pixels[0]
        image.filepath = str(texture_dir / name)
        image.filepath_raw = str(texture_dir / name)
        image.file_format = "PNG"
        image.save()
    except (RuntimeError, IndexError):
        pass

target.parent.mkdir(parents=True, exist_ok=True)
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
            "layer": "connected_setpieces",
            "definitions": loaded_definitions,
            "placements": placement_count,
            "mesh_instances": len(instances),
            "prototype_meshes": prototype_count,
            "inner_radius": 85.0,
            "outer_radius": 190.0,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
print(
    f"OPENDAO_SETPIECES instances={len(instances)} prototypes={prototype_count} output={target}"
)
