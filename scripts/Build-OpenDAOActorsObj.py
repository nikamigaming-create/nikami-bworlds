import json
import os
import re
from pathlib import Path

import bpy
from math import pi
from mathutils import Matrix, Quaternion, Vector


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
target = Path(os.environ["OPENDAO_OBJ_OUTPUT"])
native_gltf = target.suffix.lower() == ".glb"
forward_correction_degrees = float(
    os.environ.get("OPENDAO_ACTOR_FORWARD_CORRECTION_DEGREES", "180" if native_gltf else "0")
)
area = json.loads(area_path.read_text(encoding="utf-8"))
telemetry_path = os.environ.get("OPENDAO_ACTOR_TELEMETRY", "")
runtime_animation = {}
if telemetry_path:
    telemetry = json.loads(Path(telemetry_path).read_text(encoding="utf-8"))
    scene_prefix = "/root/OpenDAO/DAOScene/"
    for node in telemetry.get("nodes", []):
        path = node.get("path", "")
        animation = node.get("animation")
        if (node.get("class") != "AnimationPlayer" or not animation
                or not path.startswith(scene_prefix)):
            continue
        actor_name = path[len(scene_prefix):].split("/", 1)[0]
        runtime_animation[actor_name] = animation

bpy.ops.wm.read_factory_settings(use_empty=True)
actor_count = 0
mesh_count = 0
baked_objects = []
for actor in area.get("actors", []):
    if not actor.get("active") or not actor.get("model"):
        continue
    model = root / actor["model"]
    actor_name = model.stem
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(model), import_shading="NORMALS")
    imported = [obj for obj in bpy.context.scene.objects if obj not in before]
    p = actor["position"]
    q = actor.get("rotation", [0.0, 0.0, 0.0, 1.0])
    scale = float(actor.get("scale", 1.0))
    placement = (
        Matrix.Translation(Vector((p[0], p[1], p[2])))
        @ Quaternion((q[3], q[0], q[1], q[2])).to_matrix().to_4x4()
        # Godot's imported Character node contributes this model-local forward
        # correction. Blender bakes that Character hierarchy away, so retain
        # the equivalent turn here without altering the authored actor yaw.
        @ Matrix.Rotation(forward_correction_degrees * pi / 180.0, 4, "Z")
        @ Matrix.Scale(scale, 4)
    )
    for obj in imported:
        # Native GLB output is posed and baked below. Keep the imported
        # armature hierarchy in model space and apply placement once to each
        # evaluated mesh; transforming both armature and children here makes
        # inherited rotations cancel or double. The legacy OBJ path has no
        # retained hierarchy, so it still needs placement at import time.
        if not native_gltf:
            obj.matrix_world = placement @ obj.matrix_world
        if obj.type == "MESH":
            mesh_count += 1

    # Godot starts the same DAO ambient animation for each actor as it is
    # instantiated, so their runtime timestamps are deliberately staggered.
    # Bake each actor immediately at its captured timestamp. A single global
    # Blender frame made every actor share an arbitrary pose and was the cause
    # of the visibly twisted/back-facing crowd in the compatibility build.
    if native_gltf:
        animation = runtime_animation.get(actor_name)
        if animation is None:
            seconds = 0.0
            clip = ""
        else:
            seconds = float(animation.get("position", 0.0))
            clip = str(animation.get("current", ""))
        exact_frame = seconds * bpy.context.scene.render.fps / bpy.context.scene.render.fps_base
        frame = int(exact_frame)
        bpy.context.scene.frame_set(frame, subframe=exact_frame - frame)
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        for source in imported:
            if (source.type != "MESH" or source.hide_render or source.hide_get()
                    or source.name.startswith("Icosphere")):
                continue
            evaluated = source.evaluated_get(depsgraph)
            baked_mesh = bpy.data.meshes.new_from_object(
                evaluated, preserve_all_data_layers=True, depsgraph=depsgraph
            )
            baked = bpy.data.objects.new(
                f"{actor_name}::{source.name}_RuntimeBaked", baked_mesh
            )
            bpy.context.collection.objects.link(baked)
            baked.matrix_world = placement @ source.matrix_world
            baked_objects.append(baked)
        print(
            "OPENDAO_ACTOR_POSE",
            f"actor={actor_name}",
            f"clip={clip}",
            f"seconds={seconds:.6f}",
            f"frame={exact_frame:.6f}",
        )
    actor_count += 1

target.parent.mkdir(parents=True, exist_ok=True)
if target.suffix.lower() == ".glb":
    # OpenMW's compatibility reader does not evaluate glTF skins yet. The
    # runtime poses were baked above while each actor's skin was still live.
    for source in list(bpy.context.scene.objects):
        if source not in baked_objects:
            bpy.data.objects.remove(source, do_unlink=True)
    bpy.ops.export_scene.gltf(
        filepath=str(target),
        export_format="GLB",
        use_active_scene=True,
        export_animations=False,
        export_skins=False,
        export_morph=True,
    )
    print(f"OPENDAO_ACTORS_GLTF actors={actor_count} meshes={mesh_count} output={target}")
    print(f"OPENDAO_ACTOR_FORWARD_CORRECTION degrees={forward_correction_degrees:.3f}")
    raise SystemExit(0)

texture_dir = target.parent / f"{target.stem}-textures"
texture_dir.mkdir(parents=True, exist_ok=True)
used = set()
image_targets = {}
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
        image_targets[image] = texture_dir / name
    except (RuntimeError, IndexError):
        pass

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

material_path = target.with_suffix(".mtl")
rewritten = []
texture_prefix = texture_dir.as_posix().rstrip("/") + "/"
def find_image_upstream(socket, visited=None):
    """Return the image feeding a shader socket, following simple node chains."""
    visited = visited or set()
    for link in socket.links:
        node = link.from_node
        if node in visited:
            continue
        visited.add(node)
        if node.type == "TEX_IMAGE" and node.image in image_targets:
            return node.image
        for input_socket in node.inputs:
            image = find_image_upstream(input_socket, visited)
            if image is not None:
                return image
    return None


material_diffuse = {}
for material in bpy.data.materials:
    if not material.use_nodes:
        continue
    diffuse_image = None
    for node in material.node_tree.nodes:
        if node.type != "BSDF_PRINCIPLED":
            continue
        base_color = node.inputs.get("Base Color")
        if base_color is not None:
            diffuse_image = find_image_upstream(base_color)
        if diffuse_image is not None:
            break
    if diffuse_image is not None:
        relative = os.path.relpath(image_targets[diffuse_image], material_path.parent)
        material_diffuse[material.name] = Path(relative).as_posix()
current_material = ""
for line in material_path.read_text(encoding="utf-8-sig", errors="ignore").splitlines():
    if line.startswith("newmtl "):
        current_material = line[7:].strip()
        rewritten.append(line)
        if current_material in material_diffuse:
            rewritten.append(f"map_Kd {material_diffuse[current_material]}")
        continue
    if line.startswith(("map_Bump ", "bump ")):
        continue
    if line.startswith("map_Kd "):
        continue
    rewritten.append(line)
material_path.write_text("\n".join(rewritten) + "\n", encoding="utf-8")
print(f"OPENDAO_ACTORS actors={actor_count} meshes={mesh_count} output={target}")
