import json
import os
import re
import struct
from pathlib import Path


def glb_primitive_instances(path: Path) -> int:
    with path.open("rb") as stream:
        magic, _version, _length = struct.unpack("<III", stream.read(12))
        if magic != 0x46546C67:
            raise ValueError(f"Not a GLB: {path}")
        chunk_length, chunk_type = struct.unpack("<II", stream.read(8))
        if chunk_type != 0x4E4F534A:
            raise ValueError(f"GLB has no leading JSON chunk: {path}")
        document = json.loads(stream.read(chunk_length).decode("utf-8").rstrip("\x00 \t\r\n"))
    meshes = document.get("meshes", [])
    return sum(
        len(meshes[node["mesh"]].get("primitives", []))
        for node in document.get("nodes", [])
        if "mesh" in node
    )


def obj_material_instances(path: Path) -> int:
    with path.open(encoding="utf-8-sig", errors="ignore") as stream:
        return sum(1 for line in stream if line.startswith("usemtl "))


def mtl_diffuse_audit(path: Path) -> tuple[int, list[str]]:
    maps = 0
    missing = []
    with path.open(encoding="utf-8-sig", errors="ignore") as stream:
        for raw in stream:
            if not raw.startswith("map_Kd "):
                continue
            maps += 1
            texture = Path(raw.split(maxsplit=1)[1].strip().replace("/", os.sep))
            if not texture.is_absolute():
                texture = path.parent / texture
            if not texture.is_file():
                missing.append(str(texture))
    return maps, missing


def selected_records(definitions, predicate):
    result = []
    for key, definition in definitions.items():
        records = []
        seen = set()
        for record in definition.get("instances", []):
            if not predicate(key, record):
                continue
            position = tuple(round(float(value), 4) for value in record.get("position", [0, 0, 0]))
            rotation = tuple(round(float(value), 4) for value in record.get("rotation", [0, 0, 0, 1]))
            transform = position + rotation
            if transform in seen:
                continue
            seen.add(transform)
            records.append(record)
        if records:
            result.append((key, definition, records))
    return result


area_path = Path(os.environ["OPENDAO_AREA_INPUT"])
root = Path(os.environ["OPENDAO_AREA_ROOT"])
layer_root = Path(os.environ["OPENDAO_LAYER_ROOT"])
output = Path(os.environ["OPENDAO_PARITY_OUTPUT"])
environment_glb = Path(os.environ["OPENDAO_ENVIRONMENT_GLB"])
area = json.loads(area_path.read_text(encoding="utf-8"))
cluster = (260.0, 301.0)


def distance(record):
    p = record["position"]
    return ((p[0] - cluster[0]) ** 2 + (p[1] - cluster[1]) ** 2) ** 0.5


terrain = area.get("terrain", {}).get("patches", {})
props = area.get("props", {})
trees = area.get("trees", {})
terrain_inner = selected_records(terrain, lambda _key, record: distance(record) <= 85.0)
terrain_ring = selected_records(terrain, lambda _key, record: distance(record) > 85.0)
setpieces = selected_records(
    props,
    lambda key, record: not key.lower().startswith(("plc_", "hro_"))
    and "water" not in key.lower()
    and 85.0 < distance(record) <= 190.0,
)
vegetation = selected_records(trees, lambda _key, record: distance(record) <= 220.0)
water = selected_records(
    props,
    lambda key, _record: key.lower() == "lak100d_water_12" or key.lower().startswith("hro_lak100dwater"),
)
placeables = selected_records(props, lambda key, _record: key.lower().startswith("plc_"))


def expected_meshes(selection):
    expected = 0
    missing = []
    for key, definition, records in selection:
        model = root / definition.get("file", "")
        if not model.is_file():
            missing.append(f"{key}:{model}")
            continue
        expected += glb_primitive_instances(model) * len(records)
    return expected, missing


layers = {}
for name, selection, obj_name in (
    ("connected_terrain", terrain_ring, "redcliffe-terrain-ring.obj"),
    ("connected_setpieces", setpieces, "redcliffe-setpieces.obj"),
    ("vegetation", vegetation, "redcliffe-vegetation.obj"),
):
    expected, missing_sources = expected_meshes(selection)
    obj = layer_root / obj_name
    actual = obj_material_instances(obj) if obj.is_file() else 0
    layers[name] = {
        "definitions_expected": len(selection),
        "placements_expected": sum(len(records) for _key, _definition, records in selection),
        "mesh_primitives_expected": expected,
        "mesh_primitives_loaded": actual,
        "missing_sources": missing_sources,
        "pass": actual == expected,
    }

base_obj = layer_root / "redcliffe-environment-v2.obj"
base_expected = glb_primitive_instances(environment_glb)
base_actual = obj_material_instances(base_obj)
layers["base_environment"] = {
    "terrain_inner_definitions_expected": len(terrain_inner),
    "mesh_primitives_expected": base_expected,
    "mesh_primitives_loaded": base_actual,
    "pass": base_actual == base_expected,
}

active_actors = [actor for actor in area.get("actors", []) if actor.get("active") and actor.get("model")]
actor_expected = 0
actor_missing = []
for actor in active_actors:
    model = root / actor["model"]
    if model.is_file():
        actor_expected += glb_primitive_instances(model)
    else:
        actor_missing.append(str(model))
actor_obj = layer_root / "redcliffe-actors.obj"
actor_actual = obj_material_instances(actor_obj) if actor_obj.is_file() else 0
layers["actors"] = {
    "actors_expected": len(active_actors),
    "mesh_primitives_expected": actor_expected,
    "mesh_primitives_loaded": actor_actual,
    "missing_sources": actor_missing,
    "pass": actor_actual == actor_expected and not actor_missing,
}

material_files = sorted(layer_root.glob("*.mtl"))
missing_textures = []
diffuse_maps = 0
normal_maps_in_fixed_function_path = 0
for material_file in material_files:
    maps, missing = mtl_diffuse_audit(material_file)
    diffuse_maps += maps
    missing_textures.extend(missing)
    text = material_file.read_text(encoding="utf-8-sig", errors="ignore")
    normal_maps_in_fixed_function_path += len(re.findall(r"^(?:map_Bump|bump)\s", text, re.MULTILINE))

sky_texture = Path(os.environ["OPENDAO_SKY_TEXTURE"])
lights_expected = len(area.get("lights", []))
lights_loaded = int(os.environ.get("OPENDAO_LIGHTS_LOADED", "0"))
report = {
    "area": str(area_path),
    "layers": layers,
    "sky": {"texture": str(sky_texture), "pass": sky_texture.is_file()},
    "materials": {
        "mtl_files": len(material_files),
        "diffuse_maps": diffuse_maps,
        "missing_diffuse_textures": missing_textures,
        "normal_maps_in_fixed_function_colour_path": normal_maps_in_fixed_function_path,
        "pass": not missing_textures and normal_maps_in_fixed_function_path == 0,
    },
    "lights": {
        "authored_expected": lights_expected,
        "authored_loaded": lights_loaded,
        "pass": lights_loaded == lights_expected,
    },
    "water": {
        "definitions_expected": len(water),
        "placements_expected": sum(len(records) for _key, _definition, records in water),
        "loaded": 0,
        "pass": False,
    },
    "interactive_placeables": {
        "definitions_expected": len(placeables),
        "placements_expected": sum(len(records) for _key, _definition, records in placeables),
        "loaded": 0,
        "pass": False,
    },
}
town_keys = ["base_environment", "connected_terrain", "connected_setpieces", "vegetation", "actors"]
report["town_render_pass"] = all(layers[key]["pass"] for key in town_keys) and report["sky"]["pass"] and report["materials"]["pass"]
report["full_runtime_pass"] = report["town_render_pass"] and report["lights"]["pass"] and report["water"]["pass"] and report["interactive_placeables"]["pass"]
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, indent=2))
