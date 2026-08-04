"""Extract the authored diffuse/normal palette for every DAO terrain sector."""

import json
import os
import shutil
from pathlib import Path

import bpy


def find_image_upstream(socket, visited=None):
    visited = visited or set()
    for link in socket.links:
        node = link.from_node
        if node in visited:
            continue
        visited.add(node)
        if node.type == "TEX_IMAGE" and node.image is not None:
            return node.image
        for child in node.inputs:
            image = find_image_upstream(child, visited)
            if image is not None:
                return image
    return None


def material_images(material):
    if material is None or not material.use_nodes:
        return None, None
    principled = next(
        (node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"),
        None,
    )
    if principled is None:
        return None, None
    base = principled.inputs.get("Base Color")
    normal = principled.inputs.get("Normal")
    return (
        find_image_upstream(base) if base is not None else None,
        find_image_upstream(normal) if normal is not None else None,
    )


def save_image(image, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    image.filepath_raw = str(target)
    image.file_format = "PNG"
    image.save()


bpy.ops.wm.read_factory_settings(use_empty=True)
area_value = os.environ.get("OPENDAO_AREA_INPUT", "")
root_value = os.environ.get("OPENDAO_AREA_ROOT", "")
output_dir_value = os.environ.get("OPENDAO_PALETTE_OUTPUT_DIR", "")
manifest_value = os.environ.get("OPENDAO_TERRAIN_MANIFEST", "")

if area_value and root_value and output_dir_value:
    area = json.loads(Path(area_value).read_text(encoding="utf-8"))
    root = Path(root_value)
    output_dir = Path(output_dir_value)
    descriptors = (
        json.loads(Path(manifest_value).read_text(encoding="utf-8"))
        if manifest_value else {}
    )
    extracted = 0
    for key, definition in area.get("terrain", {}).get("patches", {}).items():
        model = root / definition["file"]
        before = set(bpy.context.scene.objects)
        bpy.ops.import_scene.gltf(filepath=str(model), import_shading="NORMALS")
        imported = [obj for obj in bpy.context.scene.objects if obj not in before]
        candidates = []
        for obj in imported:
            if obj.type == "MESH":
                candidates.extend(slot.material for slot in obj.material_slots if slot.material)
        material = next(
            (candidate for candidate in candidates if key.lower() in candidate.name.lower()),
            candidates[0] if candidates else None,
        )
        diffuse, normal = material_images(material)
        material_key = key if key.lower().endswith(".mao") else f"{key}.mao"
        if diffuse is None:
            raise RuntimeError(f"diffuse terrain palette missing for {key} in {model}")
        diffuse_target = output_dir / f"{material_key}_palette.png"
        save_image(diffuse, diffuse_target)
        normal_target = None
        if normal is not None:
            normal_target = output_dir / f"{material_key}_normal.png"
            save_image(normal, normal_target)
        descriptor = descriptors.get(material_key)
        if descriptor:
            for source_key, suffix in (("maskA", "maska"), ("maskA2", "maska2")):
                source_mask = Path(descriptor[source_key])
                target_mask = output_dir / f"{material_key}_{suffix}.png"
                shutil.copy2(source_mask, target_mask)
        print(
            "OPENDAO_TERRAIN_PALETTE",
            f"material={material_key}",
            f"diffuse={diffuse_target}",
            f"normal={normal_target or ''}",
        )
        extracted += 1
        for obj in imported:
            bpy.data.objects.remove(obj, do_unlink=True)
    print(f"OPENDAO_TERRAIN_PALETTES count={extracted} output={output_dir}")
    raise SystemExit(0)

# Backward-compatible one-material extraction used by older build recipes.
source = Path(os.environ["OPENDAO_GLTF_INPUT"])
target = Path(os.environ["OPENDAO_PALETTE_OUTPUT"])
bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")
for material in bpy.data.materials:
    if "lak100d_19_0.mao" not in material.name.lower():
        continue
    diffuse, _ = material_images(material)
    if diffuse is not None:
        save_image(diffuse, target)
        print(
            f"OPENDAO_TERRAIN_PALETTE image={diffuse.name} "
            f"size={diffuse.size[0]}x{diffuse.size[1]} output={target}"
        )
        raise SystemExit(0)
raise RuntimeError("terrain palette image was not found in lak100d_19_0.mao")
