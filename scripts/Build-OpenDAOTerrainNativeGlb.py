"""Restore DAO palette and normal atlases on an OpenDAO terrain GLB.

The OpenMW compatibility renderer performs the eight-layer mask blend at
runtime.  This Blender pass preserves geometry/transforms while replacing the
old flattened diffuse bake with the authored palette inputs.
"""

import os
from pathlib import Path

import bpy


source = Path(os.environ["OPENDAO_GLTF_INPUT"])
target = Path(os.environ["OPENDAO_GLTF_OUTPUT"])
asset_dir = Path(os.environ["OPENDAO_TERRAIN_ASSET_DIR"])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")

restored = 0
for material in bpy.data.materials:
    key = material.name.split(".")[0] if False else material.name
    marker = key.lower().find("lak100d_")
    if marker < 0:
        continue
    key = key[marker:]
    if ".mao" in key.lower():
        key = key[: key.lower().index(".mao") + 4]
    palette_path = asset_dir / f"{key}_palette.png"
    normal_path = asset_dir / f"{key}_normal.png"
    if not palette_path.is_file() or not normal_path.is_file():
        raise RuntimeError(f"missing authored terrain inputs for {key}")

    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    diffuse = nodes.new("ShaderNodeTexImage")
    diffuse.image = bpy.data.images.load(str(palette_path), check_existing=True)
    diffuse.image.colorspace_settings.name = "sRGB"
    normal_image = nodes.new("ShaderNodeTexImage")
    normal_image.image = bpy.data.images.load(str(normal_path), check_existing=True)
    normal_image.image.colorspace_settings.name = "Non-Color"
    normal = nodes.new("ShaderNodeNormalMap")
    links.new(diffuse.outputs["Color"], principled.inputs["Base Color"])
    links.new(normal_image.outputs["Color"], normal.inputs["Color"])
    links.new(normal.outputs["Normal"], principled.inputs["Normal"])
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])
    principled.inputs["Metallic"].default_value = 0.0
    principled.inputs["Roughness"].default_value = 0.72
    restored += 1

if not restored:
    raise RuntimeError("no DAO terrain materials found")

target.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=str(target),
    export_format="GLB",
    use_active_scene=True,
    export_animations=False,
    export_skins=False,
)
print(f"OPENDAO_TERRAIN_NATIVE_GLTF materials={restored} output={target}")
