import os
from pathlib import Path

import bpy


source = Path(os.environ["OPENDAO_GLTF_INPUT"])
target = Path(os.environ["OPENDAO_GLTF_OUTPUT"])
terrain_dir = Path(os.environ["OPENDAO_TERRAIN_BAKED_DIR"])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(source), import_shading="NORMALS")

replaced = 0
for material in bpy.data.materials:
    key = next(
        (name for name in ("lak100d_19_0.mao", "lak100d_23_0.mao") if name in material.name.lower()),
        None,
    )
    if key is None:
        continue
    image_path = terrain_dir / f"{key}_openmw_baked_4k.png"
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
    diffuse.interpolation = "Linear"
    links.new(diffuse.outputs["Color"], principled.inputs["Base Color"])
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])
    principled.inputs["Metallic"].default_value = 0.0
    principled.inputs["Roughness"].default_value = 0.72
    replaced += 1

if replaced != 2:
    raise RuntimeError(f"expected two inner Redcliffe terrain materials, replaced {replaced}")

target.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=str(target),
    export_format="GLB",
    use_active_scene=True,
    export_animations=True,
    export_skins=True,
)
print(f"OPENDAO_ENVIRONMENT_GLTF materials={replaced} output={target}")
