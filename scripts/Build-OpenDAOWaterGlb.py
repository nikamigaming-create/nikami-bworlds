import json
import os
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
area_root = Path(os.environ["OPENDAO_AREA_ROOT"])
output = Path(os.environ["OPENDAO_WATER_OUTPUT"])
area = json.loads(area_path.read_text(encoding="utf-8"))

bpy.ops.wm.read_factory_settings(use_empty=True)
count = 0
for key in ("hro_lak100dwater_new", "lak100d_water_12"):
    definition = area["props"][key]
    model = area_root / definition["file"]
    seen = set()
    for instance in definition["instances"]:
        signature = (tuple(instance["position"]), tuple(instance["rotation"]))
        if signature in seen:
            continue
        seen.add(signature)
        before = set(bpy.context.scene.objects)
        bpy.ops.import_scene.gltf(filepath=str(model), import_shading="NORMALS")
        imported = [obj for obj in bpy.context.scene.objects if obj not in before]
        p = instance["position"]
        q = instance.get("rotation", [0.0, 0.0, 0.0, 1.0])
        placement = (
            Matrix.Translation(Vector(p))
            @ Quaternion((q[3], q[0], q[1], q[2])).to_matrix().to_4x4()
            @ Matrix.Scale(float(instance.get("scale", 1.0)), 4)
        )
        for obj in imported:
            obj.matrix_world = placement @ obj.matrix_world
            if obj.type == "MESH":
                obj.name = f"OpenDAO_Water::{key}::{obj.name}"
                # Godot hides the source lak100d lake shell and replaces it
                # with one clean plane. Preserve that renderer-state parity in
                # the native OpenMW artifact instead of exporting two
                # coincident surfaces that z-fight and expose shell edges.
                if key == "lak100d_water_12":
                    bpy.data.objects.remove(obj, do_unlink=True)
                    continue
                for slot in obj.material_slots:
                    if slot.material:
                        slot.material.name = f"OpenDAO_Water::{key}::{slot.material.name}"
        count += 1

# Godot runtime telemetry for lak100d_water_12:
# bounds P=(-240,0,-306), S=(1000,.00001,1000), clean surface center
#=(260,.01001,194). Blender is Z-up, so Godot (x,y,z) maps to
# Blender (x,-z,y).
bpy.ops.mesh.primitive_grid_add(x_subdivisions=129, y_subdivisions=129, size=2.0, location=(260.0, -194.0, 0.01001))
clean = bpy.context.object
clean.name = "OpenDAO_Water::CleanLakeSurface"
clean.scale = (500.0, 500.0, 1.0)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
material = bpy.data.materials.new("OpenDAO_Water::CleanLakeSurface")
material.diffuse_color = (0.025, 0.105, 0.145, 0.91)
clean.data.materials.append(material)

output.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=str(output),
    export_format="GLB",
    use_active_scene=True,
    export_animations=False,
    export_skins=False,
)
print(f"OPENDAO_WATER_GLTF instances={count} output={output}")
