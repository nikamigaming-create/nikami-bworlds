"""Prepare the authored high-poly Leliana portrait as a native OpenMW glTF scene."""

import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix


SOURCE = Path(sys.argv[sys.argv.index("--") + 1])
OUTPUT = Path(sys.argv[sys.argv.index("--") + 2])
TEXTURES = Path(sys.argv[sys.argv.index("--") + 3])


def image_texture(nodes, path: Path, *, color: bool):
    node = nodes.new("ShaderNodeTexImage")
    node.image = bpy.data.images.load(str(path), check_existing=True)
    node.image.colorspace_settings.name = "sRGB" if color else "Non-Color"
    return node


def replace_portrait_material(material, *, face: bool):
    replacement = bpy.data.materials.new(material.name + " OpenMW")
    replacement.use_nodes = True
    nodes = replacement.node_tree.nodes
    links = replacement.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])

    if face:
        albedo_path = TEXTURES / "hf_hed_leliana_d.png"
        normal_path = TEXTURES / "hf_hed_leliana_Younger_N.png"
        principled.inputs["Roughness"].default_value = 0.74
        principled.inputs["Specular IOR Level"].default_value = 0.30
    else:
        albedo_path = TEXTURES / "hair_straight_thick_d.png"
        normal_path = TEXTURES / "hair_straight_thick_n.png"
        principled.inputs["Roughness"].default_value = 0.68
        principled.inputs["Specular IOR Level"].default_value = 0.12

    albedo = image_texture(nodes, albedo_path, color=True)
    normal_tex = image_texture(nodes, normal_path, color=False)
    normal = nodes.new("ShaderNodeNormalMap")
    normal.inputs["Strength"].default_value = 0.78 if face else 0.72
    links.new(albedo.outputs["Color"], principled.inputs["Base Color"])
    links.new(normal_tex.outputs["Color"], normal.inputs["Color"])
    links.new(normal.outputs["Normal"], principled.inputs["Normal"])
    if not face:
        links.new(albedo.outputs["Alpha"], principled.inputs["Alpha"])
        replacement.surface_render_method = "DITHERED"
        replacement.alpha_threshold = 0.34
    return replacement


def replace_authored_material(material, albedo_name, normal_name=None, *, alpha=False):
    replacement = bpy.data.materials.new(material.name + " OpenMW Authored")
    replacement.use_nodes = True
    nodes = replacement.node_tree.nodes
    links = replacement.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    principled.inputs["Roughness"].default_value = 0.66
    principled.inputs["Specular IOR Level"].default_value = 0.20
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])
    albedo = image_texture(nodes, TEXTURES / albedo_name, color=True)
    links.new(albedo.outputs["Color"], principled.inputs["Base Color"])
    if normal_name:
        normal_tex = image_texture(nodes, TEXTURES / normal_name, color=False)
        normal = nodes.new("ShaderNodeNormalMap")
        normal.inputs["Strength"].default_value = 0.65
        links.new(normal_tex.outputs["Color"], normal.inputs["Color"])
        links.new(normal.outputs["Normal"], principled.inputs["Normal"])
    if alpha:
        links.new(albedo.outputs["Alpha"], principled.inputs["Alpha"])
        replacement.surface_render_method = "DITHERED"
        replacement.alpha_threshold = 0.34
    return replacement


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(SOURCE))

for obj in bpy.context.scene.objects:
    if obj.type != "MESH":
        continue
    for index, material in enumerate(obj.data.materials):
        if material is None:
            continue
        semantic = f"{obj.name} {material.name}".lower()
        if "leliana face" in semantic:
            obj.data.materials[index] = replace_portrait_material(material, face=True)
        elif "leliana hair" in semantic:
            obj.data.materials[index] = replace_portrait_material(material, face=False)
        elif "eyelash" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "uh_lash_d.png", alpha=True)
        elif "eyes" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "uh_eye_dark_d.png", "uh_eye_dark_n.png")
        elif "arms" in semantic or ("leliana body" in semantic and "face" not in semantic):
            obj.data.materials[index] = replace_authored_material(material, "bdy_hf_leliana01_0d.png", "bdy_hf_leliana01_0n.png")
        elif "shoulder" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "Shoulderu_acce_color.png", "Shoulderu_acce_normal.png")
        elif "glove" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "Glovesl_wrist_color.png", "Glovesl_wrist_normal.png")
        elif "quiver" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "W_QUI_QU101a_0d.png", "W_QUI_QU101a_0n.png")
        elif "bow" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "w_lbw_001a_d.png", "w_lbw_001a_n.png")
        elif "arrow" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "gen_arrow_D.png", "gen_arrow_N.png")
        elif "armor" in semantic or "leather" in semantic or "belt" in semantic:
            obj.data.materials[index] = replace_authored_material(material, "yifu01_Base_Color.jpg", "yifu01_Normal_OpenGL.jpg")

# Place the accepted portrait just in front of Redcliffe's terrain shell.
# OpenMW's world viewer is Z-up and maps Godot -Z to +Y.
OPENMW_PRESENTATION_SCALE = 30.0
placement = (
    # Keep the lowest exported accessory at the accepted Redcliffe floor while
    # scaling the portrait out of OpenMW's Bethesda-unit near clip.
    Matrix.Translation((256.0, 300.5, 50.0))
    @ Matrix.Rotation(math.radians(156.0), 4, "Z")
    @ Matrix.Scale(OPENMW_PRESENTATION_SCALE, 4)
)
# The imported GLB has a Y-up conversion parent. Flatten every render mesh to
# world space before applying OpenMW's Z-up placement, otherwise OBJ export
# applies that conversion a second time and swaps the vertical/world axes.
render_objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
world_matrices = {obj: obj.matrix_world.copy() for obj in render_objects}
bpy.ops.object.select_all(action="DESELECT")
for obj in render_objects:
    obj.parent = None
    obj.matrix_world = placement @ world_matrices[obj]
    obj.select_set(True)

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
if OUTPUT.suffix.lower() == ".obj":
    bpy.ops.wm.obj_export(
        filepath=str(OUTPUT),
        export_selected_objects=True,
        # OSG's OBJ reader applies the Y-up to Z-up conversion itself.
        forward_axis="NEGATIVE_Z",
        up_axis="Y",
        apply_modifiers=True,
        export_uv=True,
        export_normals=True,
        export_materials=True,
        export_pbr_extensions=True,
        path_mode="COPY",
        export_triangulated_mesh=True,
    )
    # OSG's OBJ reader treats Blender's optional bump multiplier as part of
    # the filename. Preserve the authored normal maps with its supported form.
    mtl_path = OUTPUT.with_suffix(".mtl")
    mtl_text = mtl_path.read_text(encoding="utf-8")
    import re
    mtl_text = re.sub(r"(?m)^map_Bump\s+-bm\s+\S+\s+", "map_Bump ", mtl_text)
    # Blender omits legacy diffuse/ambient coefficients for node-textured
    # materials. OSG's OBJ path still multiplies the texture by those values.
    # Supply neutral coefficients so the authored skin and hair albedo survive.
    blocks = re.split(r"(?=^newmtl )", mtl_text, flags=re.MULTILINE)
    for index, block in enumerate(blocks):
        if "map_Kd " in block and "\nKd " not in block:
            first_line, remainder = block.split("\n", 1)
            blocks[index] = first_line + "\nKa 0.350000 0.350000 0.350000\nKd 1.000000 1.000000 1.000000\n" + remainder
        if block.startswith("newmtl Leliana_Face_OpenMW"):
            blocks[index] = re.sub(r"(?m)^Ka .*$", "Ka 1.000000 1.000000 1.000000", blocks[index])
            blocks[index] = re.sub(r"(?m)^illum .*$", "illum 1", blocks[index])
            blocks[index] = re.sub(r"(?m)^map_Bump .*$\n?", "", blocks[index])
        if block.startswith("newmtl Leliana_Hair_OpenMW"):
            # map_Kd already carries the authored alpha. OSG multiplies map_d
            # by it a second time and discards the hair cards.
            blocks[index] = re.sub(r"(?m)^map_d .*$\n?", "", blocks[index])
    mtl_text = "".join(blocks)
    mtl_path.write_text(mtl_text, encoding="utf-8")
else:
    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT),
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_animations=False,
        export_skins=False,
        export_morph=False,
        export_materials="EXPORT",
        export_image_format="AUTO",
        export_texcoords=True,
        export_normals=True,
        export_tangents=True,
    )
print(f"LELIANA_OPENMW_EXPORT output={OUTPUT}")
