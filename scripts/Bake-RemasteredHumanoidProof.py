#!/usr/bin/env python3
"""Bake locally-owned Oblivion Remastered modular characters to a posed OBJ.

The input meshes stay in the user's ignored local cache.  This utility reads the
UE5 glTF exports and an ActorX PSA idle, performs CPU skinning for one frame, and
writes a static proof mesh that OpenSceneGraph can consume after DAE conversion.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import struct
from dataclasses import dataclass

import numpy as np
from PIL import Image


COMPONENT_DTYPES = {
    5120: np.int8,
    5121: np.uint8,
    5122: np.int16,
    5123: np.uint16,
    5125: np.uint32,
    5126: np.float32,
}
TYPE_WIDTHS = {
    "SCALAR": 1,
    "VEC2": 2,
    "VEC3": 3,
    "VEC4": 4,
    "MAT4": 16,
}


def quaternion_matrix(q: np.ndarray) -> np.ndarray:
    x, y, z, w = (float(v) for v in q)
    length = math.sqrt(x * x + y * y + z * z + w * w)
    if length == 0:
        return np.eye(3, dtype=np.float64)
    x, y, z, w = x / length, y / length, z / length, w / length
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ],
        dtype=np.float64,
    )


def quaternion_multiply(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    ax, ay, az, aw = (float(v) for v in a)
    bx, by, bz, bw = (float(v) for v in b)
    return np.array(
        [
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ],
        dtype=np.float64,
    )


def normalized_quaternion(q: np.ndarray) -> np.ndarray:
    result = np.asarray(q, dtype=np.float64)
    length = np.linalg.norm(result)
    return result / length if length else np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float64)


def trs_matrix(translation, rotation, scale) -> np.ndarray:
    result = np.eye(4, dtype=np.float64)
    result[:3, :3] = quaternion_matrix(np.asarray(rotation)) @ np.diag(np.asarray(scale))
    result[:3, 3] = np.asarray(translation)
    return result


@dataclass
class Glb:
    path: pathlib.Path
    document: dict
    binary: bytes

    @classmethod
    def read(cls, path: pathlib.Path) -> "Glb":
        data = path.read_bytes()
        magic, version, total_length = struct.unpack_from("<III", data, 0)
        if magic != 0x46546C67 or version != 2 or total_length != len(data):
            raise ValueError(f"Not a valid glTF 2 GLB: {path}")
        offset = 12
        document = None
        binary = b""
        while offset < len(data):
            chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
            offset += 8
            payload = data[offset : offset + chunk_length]
            offset += chunk_length
            if chunk_type == 0x4E4F534A:
                document = json.loads(payload.rstrip(b" \0"))
            elif chunk_type == 0x004E4942:
                binary = payload
        if document is None:
            raise ValueError(f"GLB has no JSON chunk: {path}")
        return cls(path, document, binary)

    def accessor(self, index: int) -> np.ndarray:
        accessor = self.document["accessors"][index]
        view = self.document["bufferViews"][accessor["bufferView"]]
        dtype = np.dtype(COMPONENT_DTYPES[accessor["componentType"]]).newbyteorder("<")
        width = TYPE_WIDTHS[accessor["type"]]
        count = accessor["count"]
        offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        packed_stride = dtype.itemsize * width
        stride = view.get("byteStride", packed_stride)
        if stride == packed_stride:
            result = np.frombuffer(self.binary, dtype=dtype, count=count * width, offset=offset).reshape(count, width)
        else:
            result = np.ndarray(
                (count, width), dtype=dtype, buffer=self.binary, offset=offset, strides=(stride, dtype.itemsize)
            )
        result = np.array(result, copy=True)
        if accessor.get("normalized") and not np.issubdtype(dtype, np.floating):
            info = np.iinfo(dtype)
            if np.issubdtype(dtype, np.signedinteger):
                result = np.maximum(result.astype(np.float64) / info.max, -1.0)
            else:
                result = result.astype(np.float64) / info.max
        return result

    def local_matrix(self, node_index: int, animation: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]) -> np.ndarray:
        node = self.document["nodes"][node_index]
        name = node.get("name", "")
        if name in animation:
            translation, rotation, scale = animation[name]
            return trs_matrix(translation, rotation, scale)
        if "matrix" in node:
            return np.asarray(node["matrix"], dtype=np.float64).reshape(4, 4).T
        return trs_matrix(
            node.get("translation", [0, 0, 0]),
            node.get("rotation", [0, 0, 0, 1]),
            node.get("scale", [1, 1, 1]),
        )

    def globals(self, animation: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]) -> list[np.ndarray]:
        nodes = self.document["nodes"]
        parents = {child: parent for parent, node in enumerate(nodes) for child in node.get("children", [])}
        result: list[np.ndarray | None] = [None] * len(nodes)

        def resolve(index: int) -> np.ndarray:
            if result[index] is not None:
                return result[index]  # type: ignore[return-value]
            local = self.local_matrix(index, animation)
            result[index] = resolve(parents[index]) @ local if index in parents else local
            return result[index]  # type: ignore[return-value]

        for index in range(len(nodes)):
            resolve(index)
        return result  # type: ignore[return-value]


def parse_psa_frame(path: pathlib.Path, frame: int) -> dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]:
    data = path.read_bytes()
    offset = 0
    chunks = {}
    while offset + 32 <= len(data):
        raw_name, type_flag, size, count = struct.unpack_from("<20siii", data, offset)
        offset += 32
        name = raw_name.split(b"\0", 1)[0].decode("ascii")
        chunks[name] = (type_flag, size, count, offset)
        offset += size * count

    _, bone_size, bone_count, bone_offset = chunks["BONENAMES"]
    bones = []
    for index in range(bone_count):
        cursor = bone_offset + index * bone_size
        name = data[cursor : cursor + 64].split(b"\0", 1)[0].decode("utf-8", "replace")
        bones.append(name)

    _, info_size, _, info_offset = chunks["ANIMINFO"]
    info = struct.unpack_from("<64s64siiiifffiii", data, info_offset)
    total_bones = info[2]
    frames = info[-1]
    if total_bones != bone_count:
        raise ValueError(f"PSA bone mismatch: header={total_bones}, names={bone_count}")
    frame = max(0, min(frame, frames - 1))

    _, key_size, _, key_offset = chunks["ANIMKEYS"]
    _, scale_size, _, scale_offset = chunks["SCALEKEYS"]
    animation = {}
    for bone_index, name in enumerate(bones):
        key_cursor = key_offset + (frame * bone_count + bone_index) * key_size
        px, py, pz, qx, qy, qz, qw, _ = struct.unpack_from("<8f", data, key_cursor)
        scale_cursor = scale_offset + (frame * bone_count + bone_index) * scale_size
        sx, sy, sz, _ = struct.unpack_from("<4f", data, scale_cursor)

        # ActorX mirrors Unreal Y when writing PSA.  The glTF exporter maps UE
        # (X,Y,Z) to glTF (X,Z,Y) and converts centimetres to metres.
        translation = np.array([px, pz, -py], dtype=np.float64) * 0.01
        rotation = np.array([qx, qz, -qy, -qw if bone_index == 0 else qw], dtype=np.float64)
        scale = np.array([sx, sz, sy], dtype=np.float64)
        animation[name] = (translation, rotation, scale)
    return animation


def neutral_face_overrides(
    asset_root: pathlib.Path, close_degrees: float
) -> dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]:
    if close_degrees == 0:
        return {}
    head_path = (
        asset_root
        / "OblivionRemastered"
        / "Content"
        / "Art"
        / "Character"
        / "DarkElf"
        / "SK_DarkElf_Head_m.glb"
    )
    head = Glb.read(head_path)
    radians = math.radians(close_degrees)
    delta = np.array([math.sin(radians * 0.5), 0.0, 0.0, math.cos(radians * 0.5)], dtype=np.float64)
    overrides = {}
    for node in head.document["nodes"]:
        name = node.get("name", "")
        if name not in {"FACIAL_C_Jaw", "FACIAL_C_LowerLipRotation"}:
            continue
        translation = np.asarray(node.get("translation", [0, 0, 0]), dtype=np.float64)
        rotation = np.asarray(node.get("rotation", [0, 0, 0, 1]), dtype=np.float64)
        scale = np.asarray(node.get("scale", [1, 1, 1]), dtype=np.float64)
        overrides[name] = (translation, quaternion_multiply(rotation, delta), scale)
    return overrides


def retarget_idle_limbs(
    reference_path: pathlib.Path,
    source_animation: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]],
) -> dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]:
    """Retarget an idle without replacing the modular character's bind skeleton.

    ActorX animation translations are valid for the source skeleton but replacing
    every modular mesh transform can open seams at the neck and wrists.  Keeping
    the exported bind translations while borrowing only the major idle rotations
    produces a connected, recognisably relaxed proof pose instead of an A/T pose.
    """
    reference = Glb.read(reference_path)
    animated_bones = {
        "clavicle_l",
        "upperarm_l",
        "lowerarm_l",
        "hand_l",
        "clavicle_r",
        "upperarm_r",
        "lowerarm_r",
        "hand_r",
        "thigh_l",
        "calf_l",
        "foot_l",
        "ball_l",
        "thigh_r",
        "calf_r",
        "foot_r",
        "ball_r",
    }
    overrides = {}
    for node in reference.document["nodes"]:
        name = node.get("name", "")
        if name not in animated_bones or name not in source_animation:
            continue
        translation = np.asarray(node.get("translation", [0, 0, 0]), dtype=np.float64)
        rotation = normalized_quaternion(source_animation[name][1])
        scale = np.asarray(node.get("scale", [1, 1, 1]), dtype=np.float64)
        overrides[name] = (translation, rotation, scale)
    return overrides


def skin_primitive(
    glb: Glb,
    node_index: int,
    primitive: dict,
    animation: dict,
    target_names: list[str],
    morph_weights: dict[str, float],
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    attrs = primitive["attributes"]
    positions = glb.accessor(attrs["POSITION"]).astype(np.float64)
    normals = glb.accessor(attrs["NORMAL"]).astype(np.float64)
    texcoords = glb.accessor(attrs["TEXCOORD_0"]).astype(np.float64)
    indices = glb.accessor(primitive["indices"]).reshape(-1).astype(np.int64)
    targets = primitive.get("targets", [])
    if len(targets) == len(target_names):
        for target_name, target in zip(target_names, targets):
            weight = morph_weights.get(target_name, 0.0)
            if weight == 0:
                continue
            if "POSITION" in target:
                positions += glb.accessor(target["POSITION"]).astype(np.float64) * weight
            if "NORMAL" in target:
                normals += glb.accessor(target["NORMAL"]).astype(np.float64) * weight
    globals_ = glb.globals(animation)
    node = glb.document["nodes"][node_index]

    if "skin" not in node or "JOINTS_0" not in attrs:
        transform = globals_[node_index]
        normal_transform = np.linalg.inv(transform[:3, :3]).T
        positions = (transform @ np.column_stack([positions, np.ones(len(positions))]).T).T[:, :3]
        normals = (normal_transform @ normals.T).T
    else:
        skin = glb.document["skins"][node["skin"]]
        joints = glb.accessor(attrs["JOINTS_0"]).astype(np.int64)
        weights = glb.accessor(attrs["WEIGHTS_0"]).astype(np.float64)
        inverse_binds = glb.accessor(skin["inverseBindMatrices"]).astype(np.float64)
        inverse_binds = inverse_binds.reshape((-1, 4, 4)).transpose(0, 2, 1)
        matrices = np.stack([globals_[joint] @ inverse_binds[i] for i, joint in enumerate(skin["joints"])])
        normal_matrices = np.linalg.inv(matrices[:, :3, :3]).transpose(0, 2, 1)
        homogeneous = np.column_stack([positions, np.ones(len(positions))])
        posed_positions = np.zeros((len(positions), 3), dtype=np.float64)
        posed_normals = np.zeros((len(normals), 3), dtype=np.float64)
        weight_sum = weights.sum(axis=1)
        weights = np.divide(weights, weight_sum[:, None], out=np.zeros_like(weights), where=weight_sum[:, None] > 0)
        for influence in range(joints.shape[1]):
            ids = joints[:, influence]
            influence_weights = weights[:, influence]
            for joint_id in np.unique(ids[influence_weights > 0]):
                mask = (ids == joint_id) & (influence_weights > 0)
                posed_positions[mask] += (
                    (matrices[joint_id] @ homogeneous[mask].T).T[:, :3] * influence_weights[mask, None]
                )
                posed_normals[mask] += (
                    (normal_matrices[joint_id] @ normals[mask].T).T * influence_weights[mask, None]
                )
        positions = posed_positions
        normals = posed_normals

    lengths = np.linalg.norm(normals, axis=1)
    normals = np.divide(normals, lengths[:, None], out=np.zeros_like(normals), where=lengths[:, None] > 0)
    return positions, normals, texcoords, indices.reshape(-1, 3)


def close_mouth_boundary(
    vertices: np.ndarray, texcoords: np.ndarray, faces: np.ndarray
) -> np.ndarray:
    """Collapse the exported open-mouth rim to the neutral lip line.

    The UE head is authored with a real mouth cavity.  Static rest-pose proofs
    have no facial animation driving the two rims together, so the cavity reads
    as a black rectangle.  The mouth rim has a dedicated UV boundary around the
    painted neutral lip line; collapsing only that boundary preserves the face
    surface, UVs, and all non-mouth geometry.
    """
    edges = np.sort(
        np.concatenate((faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]), axis=0),
        axis=1,
    )
    unique_edges, edge_counts = np.unique(edges, axis=0, return_counts=True)
    boundary = np.unique(unique_edges[edge_counts == 1])
    mouth_uv = boundary[
        (texcoords[boundary, 0] >= 0.40)
        & (texcoords[boundary, 0] <= 0.60)
        & (texcoords[boundary, 1] >= 0.575)
        & (texcoords[boundary, 1] <= 0.595)
    ]
    if len(mouth_uv) < 20:
        raise ValueError(f"Could not identify the Remastered mouth boundary ({len(mouth_uv)} vertices)")

    mouth_min = vertices[mouth_uv].min(axis=0)
    mouth_max = vertices[mouth_uv].max(axis=0)
    padding = np.array([0.0015, 0.0015, 0.0015], dtype=np.float64)
    duplicate_rim = boundary[
        np.all(vertices[boundary] >= mouth_min - padding, axis=1)
        & np.all(vertices[boundary] <= mouth_max + padding, axis=1)
    ]
    lip_line = float(np.median(vertices[mouth_uv, 1]))
    result = vertices.copy()
    result[duplicate_rim, 1] = lip_line
    return result


def relax_rest_geometry(vertices: np.ndarray, normals: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Turn the connected UE bind A-pose into a conservative standing idle.

    The exported modular pieces share a perfectly connected bind pose, while
    direct ActorX rotations use a different skeleton basis.  A weighted rigid
    shoulder rotation lowers the arms without touching the head, torso centre,
    or straight bind-pose legs.  The fade across the shoulder prevents seams
    between the cuirass, sleeves, gauntlets, and body.
    """
    result = vertices.copy()
    result_normals = normals.copy()
    shoulder_y = 1.39
    shoulder_x = 0.18
    lateral = np.abs(vertices[:, 0])
    weights = np.clip((lateral - shoulder_x) / 0.18, 0.0, 1.0)
    weights *= np.clip((vertices[:, 1] - 0.67) / 0.22, 0.0, 1.0)
    for side, degrees in ((-1.0, 22.0), (1.0, -28.0)):
        mask = (vertices[:, 0] * side > 0) & (weights > 0)
        if not np.any(mask):
            continue
        radians = math.radians(degrees)
        c, s = math.cos(radians), math.sin(radians)
        rotation = np.array([[c, -s], [s, c]], dtype=np.float64)
        pivot = np.array([side * shoulder_x, shoulder_y], dtype=np.float64)
        xy = vertices[mask, :2]
        rotated_xy = (rotation @ (xy - pivot).T).T + pivot
        blend = weights[mask, None]
        result[mask, :2] = xy * (1.0 - blend) + rotated_xy * blend

        normal_xy = normals[mask, :2]
        rotated_normal_xy = (rotation @ normal_xy.T).T
        result_normals[mask, :2] = normal_xy * (1.0 - blend) + rotated_normal_xy * blend
    lengths = np.linalg.norm(result_normals, axis=1)
    result_normals = np.divide(
        result_normals,
        lengths[:, None],
        out=np.zeros_like(result_normals),
        where=lengths[:, None] > 0,
    )
    return result, result_normals


def material_texture(
    asset_root: pathlib.Path, material: str, female: bool, cast: str = "aleswell"
) -> pathlib.Path | None:
    content = asset_root / "OblivionRemastered" / "Content"
    darkelf = content / "Art" / "Character" / "DarkElf"
    imperial = content / "Art" / "Character" / "Imperial"
    clothes = content / "Art" / "Clothes" / "LowerClass" / "01"
    palace = content / "Art" / "Armor" / "ImperialPalace"
    equipment = content / "Art" / "Equipment" / "armor"
    if "Imperial_Head_m" in material:
        return imperial / "T_Imperial_Head_M_01_D.png"
    if "Imperial_Body_m" in material:
        return imperial / "T_Imperial_Body_M_D.png"
    if "Imperial_Eyes" in material:
        return imperial / "T_ModularSkin_Eye_Imperial_M.png"
    if "ImperialGuard_Cuirass" in material:
        return palace / "T_Imperial_Armor_Cuirass_D.png"
    if "ImperialPalace_Greaves" in material:
        return palace / "T_Imperial_Armor_Greaves_D.png"
    if "ImperialPalace_Gauntlets" in material:
        return palace / "T_Imperial_Armor_Gauntlets_D.png"
    if "ImperialPalace_Boots" in material:
        return palace / "T_Imperial_Armor_Boots_D.png"
    if "ImperialPalace_Helmet" in material:
        return palace / "T_Imperial_Armor_Helmet_D.png"
    if "Legion_Helmet_Fur" in material:
        return build_helmet_fur_textures(asset_root)[0]
    if "ImperialPalace_Shield" in material:
        return equipment / "T_ImperialPalace_Shield_D.png"
    if "DarkElf_Head" in material:
        return darkelf / ("T_DarkElf_Head_F_01_D.png" if female else "T_DarkElf_Head_M_01_D.png")
    if "DarkElf_Body" in material:
        return darkelf / ("T_DarkElf_Body_F_D.png" if female else "T_DarkElf_Body_M_D.png")
    if "DarkElf_Eye" in material:
        return darkelf / ("T_ModularSkin_Eye_DarkElf_F.png" if female else "T_ModularSkin_Eye_DarkElf_M.png")
    if "Underwear" in material:
        return imperial / ("T_Imperial_Underwear_F_D.png" if female else "T_Imperial_Underwear_m_D.png")
    if "Teeth" in material:
        return imperial / "T_teeth_D.png"
    if "LC_01_Shirt" in material:
        return clothes / "T_LC_01_Shirt_D.png"
    if "LC_01_Pants" in material:
        return clothes / "T_LC_01_Pants_D.png"
    if "LC_01_Shoes" in material:
        return clothes / "T_LC_01_Shoes_D.png"
    if "HR_MediumBobMessy" in material or "HR_ShortCasual" in material:
        return build_hair_textures(asset_root, material)[0]
    return None


def material_instance(
    asset_root: pathlib.Path, material: str, female: bool, cast: str = "aleswell"
) -> pathlib.Path | None:
    """Return the exported UE material instance that owns a mesh material.

    The OBJ/DAE bridge cannot replay an Unreal material graph, but retaining
    its BaseTint and surface class is materially better than treating skin,
    cloth, leather, and plate as the same glossy plastic.
    """
    content = asset_root / "OblivionRemastered" / "Content"
    darkelf = content / "Art" / "Character" / "DarkElf"
    imperial = content / "Art" / "Character" / "Imperial"
    clothes = content / "Art" / "Clothes" / "LowerClass" / "01"
    palace = content / "Art" / "Armor" / "ImperialPalace"
    equipment = content / "Art" / "Equipment" / "armor"
    mappings = (
        ("Imperial_Head_m", imperial / "MIC_Imperial_Head_m_01.json"),
        ("Imperial_Body_m", imperial / "MIC_Imperial_Body_m.json"),
        ("Imperial_Eyes", imperial / "MIC_Imperial_Eyes.json"),
        ("ImperialGuard_Cuirass", palace / "MIC_ImperialGuard_Cuirass.json"),
        ("ImperialPalace_Greaves", palace / "MIC_ImperialPalace_Greaves.json"),
        ("ImperialPalace_Gauntlets", palace / "MIC_ImperialPalace_Gauntlets.json"),
        ("ImperialPalace_Boots", palace / "MIC_ImperialPalace_Boots.json"),
        ("ImperialPalace_Helmet", palace / "MIC_ImperialPalace_Helmet.json"),
        ("ImperialPalace_Shield", equipment / "MIC_ImperialPalace_Shield.json"),
        ("DarkElf_Head", darkelf / ("MIC_DarkElf_Head_f_01.json" if female else "MIC_DarkElf_Head_M_01.json")),
        ("DarkElf_Body", darkelf / ("MIC_DarkElf_Body_f.json" if female else "MIC_DarkElf_Body_m.json")),
        ("DarkElf_Eye", darkelf / "MIC_DarkElf_Eye.json"),
        ("Underwear", imperial / ("MIC_Imperial_Underwear_f.json" if female else "MIC_Imperial_Underwear_m.json")),
        ("Teeth", imperial / "MIC_Imperial_Teeth.json"),
        ("LC_01_Shirt", clothes / "MIC_LC_01_Shirt.json"),
        ("LC_01_Pants", clothes / "MIC_LC_01_Pants.json"),
        ("LC_01_Shoes", clothes / "MIC_LC_01_Shoes.json"),
    )
    for token, path in mappings:
        if token in material and path.exists():
            return path
    return None


def material_surface(
    asset_root: pathlib.Path, material: str, female: bool, cast: str = "aleswell"
) -> dict[str, tuple[float, ...] | float]:
    """Collapse the useful UE surface values to a conservative Phong bridge."""
    tint = np.ones(3, dtype=np.float64)
    instance_path = material_instance(asset_root, material, female, cast)
    if instance_path is not None:
        instance = json.loads(instance_path.read_text(encoding="utf-8"))
        value = instance.get("Parameters", {}).get("Colors", {}).get("BaseTint")
        if value is not None:
            tint = np.array([value["R"], value["G"], value["B"]], dtype=np.float64)
    lower = material.lower()
    tint = np.clip(tint, 0.0, 1.0)
    if any(
        token in lower
        for token in (
            "head",
            "body",
            "eye",
            "teeth",
            "cuirass",
            "greaves",
            "gauntlets",
            "helmet",
            "shield",
        )
    ):
        # These exported textures already contain their authored colour.  The
        # UE BaseTint values belong to a wider material graph; multiplying them
        # directly into a one-texture Phong bridge crushes skin channels and
        # turns the palace set solid blue.
        tint = np.ones(3, dtype=np.float64)
    else:
        # Retain a visible portion of clothing palette tint without discarding
        # the diffuse texture's weave, dirt, and folds.
        tint = 0.55 + (0.45 * tint)

    if "eye" in lower:
        specular, shininess, ambient = 0.16, 36.0, 0.58
    elif any(token in lower for token in ("cuirass", "greaves", "gauntlets", "helmet")):
        # This remains a compatibility approximation.  Keep plate distinct,
        # but avoid the uniform hard highlight that made every piece plastic.
        specular, shininess, ambient = 0.11, 24.0, 0.52
    elif any(token in lower for token in ("shield", "boots", "shoes")):
        specular, shininess, ambient = 0.035, 8.0, 0.58
    elif any(token in lower for token in ("shirt", "pants", "underwear", "hair", "fur")):
        specular, shininess, ambient = 0.008, 3.0, 0.62
    elif any(token in lower for token in ("head", "body")):
        specular, shininess, ambient = 0.025, 7.0, 0.60
    else:
        specular, shininess, ambient = 0.02, 5.0, 0.58
    return {
        "diffuse": tuple(float(v) for v in tint),
        "ambient": tuple(float(v * ambient) for v in tint),
        "specular": (specular, specular, specular),
        "shininess": shininess,
    }


def material_opacity(asset_root: pathlib.Path, material: str) -> pathlib.Path | None:
    if "Legion_Helmet_Fur" in material:
        return build_helmet_fur_textures(asset_root)[1]
    if "HR_MediumBobMessy" in material or "HR_ShortCasual" in material:
        return build_hair_textures(asset_root, material)[1]
    return None


def build_hair_textures(asset_root: pathlib.Path, material: str) -> tuple[pathlib.Path, pathlib.Path]:
    style = "MediumBobMessy" if "MediumBobMessy" in material else "ShortCasual"
    hair_root = asset_root / "OblivionRemastered" / "Content" / "Art" / "Character" / "Hair" / "Imperial"
    packed_path = hair_root / f"T_Imperial_HR_{style}_RAUD.png"
    instance_path = hair_root / f"MIC_Imperial_HR_{style}.json"
    output_root = asset_root / "proof" / "textures"
    output_root.mkdir(parents=True, exist_ok=True)
    diffuse_path = output_root / f"T_Imperial_HR_{style}_proof_D.png"
    opacity_path = output_root / f"T_Imperial_HR_{style}_proof_A.png"

    instance = json.loads(instance_path.read_text(encoding="utf-8"))
    colours = instance["Parameters"]["Colors"]

    def colour(name: str) -> np.ndarray:
        value = colours[name]
        return np.array([value["R"], value["G"], value["B"]], dtype=np.float64)

    packed = np.asarray(Image.open(packed_path).convert("RGBA"), dtype=np.uint8)
    root_weight = packed[:, :, 0:1].astype(np.float64) / 255.0
    strand_variation = 0.78 + 0.22 * (packed[:, :, 2:3].astype(np.float64) / 255.0)
    rgb = (colour("TipColor") * (1.0 - root_weight) + colour("RootColor") * root_weight)
    rgb = np.clip(rgb * strand_variation, 0.0, 1.0)
    opacity = packed[:, :, 1]
    diffuse = np.concatenate(
        [(np.power(rgb, 1.0 / 2.2) * 255.0 + 0.5).astype(np.uint8), opacity[:, :, None]], axis=2
    )
    Image.fromarray(diffuse, mode="RGBA").save(diffuse_path)
    Image.fromarray(opacity, mode="L").save(opacity_path)
    return diffuse_path, opacity_path


def build_helmet_fur_textures(asset_root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    content = asset_root / "OblivionRemastered" / "Content"
    instance_path = content / "Art" / "Armor" / "Legion" / "MIC_Legion_Helmet_Fur.json"
    packed_path = content / "Art" / "Armor" / "Ebony" / "T_Ebony_Fur_RAUD.png"
    output_root = asset_root / "proof" / "textures"
    output_root.mkdir(parents=True, exist_ok=True)
    diffuse_path = output_root / "T_Legion_Helmet_Fur_proof_D.png"
    opacity_path = output_root / "T_Legion_Helmet_Fur_proof_A.png"

    instance = json.loads(instance_path.read_text(encoding="utf-8"))
    colours = instance["Parameters"]["Colors"]

    def colour(name: str) -> np.ndarray:
        value = colours[name]
        return np.array([value["R"], value["G"], value["B"]], dtype=np.float64)

    packed = np.asarray(Image.open(packed_path).convert("RGBA"), dtype=np.uint8)
    root_weight = packed[:, :, 0:1].astype(np.float64) / 255.0
    strand_variation = 0.72 + 0.28 * (packed[:, :, 2:3].astype(np.float64) / 255.0)
    rgb = colour("TipColor") * (1.0 - root_weight) + colour("RootColor") * root_weight
    rgb = np.clip(rgb * strand_variation, 0.0, 1.0)
    # UE's RAUD pack stores the fur-card depth/coverage in the fourth channel.
    opacity = packed[:, :, 3:4]
    diffuse = np.concatenate(
        [(np.power(rgb, 1.0 / 2.2) * 255.0 + 0.5).astype(np.uint8), opacity], axis=2
    )
    Image.fromarray(diffuse, mode="RGBA").save(diffuse_path)
    Image.fromarray(opacity[:, :, 0], mode="L").save(opacity_path)
    return diffuse_path, opacity_path


def module_paths(
    asset_root: pathlib.Path, female: bool, hair_style: str, cast: str = "aleswell"
) -> list[pathlib.Path]:
    art = asset_root / "OblivionRemastered" / "Content" / "Art"
    if cast == "imperial-guard":
        return [
            art / "Character" / "Imperial" / "SK_Imperial_Head_m.glb",
            art / "Armor" / "ImperialPalace" / "SK_ImperialPalace_Cuirass_m.glb",
            art / "Armor" / "ImperialPalace" / "SK_ImperialPalace_Greaves_m.glb",
            art / "Armor" / "ImperialPalace" / "SK_ImperialPalace_Gauntlets.glb",
            art / "Armor" / "ImperialPalace" / "SK_ImperialPalace_Boots_m.glb",
            art / "Armor" / "ImperialPalace" / "SM_ImperialPalace_Helmet_m.glb",
            art / "Equipment" / "armor" / "SM_ImperialPalace_Shield.glb",
        ]
    suffix = "f" if female else "m"
    paths = [
        art / "Character" / "DarkElf" / f"SK_DarkElf_Body_{suffix}.glb",
        art / "Character" / "DarkElf" / f"SK_DarkElf_Head_{suffix}.glb",
        art / "Clothes" / "LowerClass" / "01" / f"SK_LC_01_Shirt_{suffix}.glb",
        art / "Clothes" / "LowerClass" / "01" / f"SK_LC_01_Pants_{suffix}.glb",
        art / "Clothes" / "LowerClass" / "01" / f"SK_LC_01_Shoes_{suffix}.glb",
    ]
    hair_name = "SK_Elf_HR_MediumBobMessy_f.glb" if hair_style == "bob" else "SK_Elf_HR_ShortCasual.glb"
    paths.append(art / "Character" / "Hair" / "Elf" / hair_name)
    return paths


def bake_actor(
    asset_root: pathlib.Path,
    female: bool,
    hair_style: str,
    animation: dict,
    morph_weights: dict[str, float],
    hide_teeth: bool,
    close_mouth: bool,
    cast: str = "aleswell",
    relaxed_pose: bool = False,
) -> list[dict]:
    parts = []
    for path in module_paths(asset_root, female, hair_style, cast):
        glb = Glb.read(path)
        for node_index, node in enumerate(glb.document["nodes"]):
            if "mesh" not in node:
                continue
            mesh = glb.document["meshes"][node["mesh"]]
            extras = mesh.get("extras", {})
            if isinstance(extras, str):
                extras = json.loads(extras)
            target_names = extras.get("targetNames", [])
            for primitive_index, primitive in enumerate(mesh["primitives"]):
                material_index = primitive.get("material")
                material = (
                    glb.document.get("materials", [])[material_index].get("name", "plain")
                    if material_index is not None
                    else "plain"
                )
                if (
                    "Fluid" in material
                    or "EyeOcclusion" in material
                    or "Eyelashes" in material
                    or (hide_teeth and "Teeth" in material)
                ):
                    continue
                vertices, normals, texcoords, faces = skin_primitive(
                    glb, node_index, primitive, animation, target_names, morph_weights
                )
                if close_mouth and "Head" in material:
                    vertices = close_mouth_boundary(vertices, texcoords, faces)
                if cast == "imperial-guard" and "Helmet" in material:
                    # The static helmet export is socket-relative. Align its
                    # metal shell with the baked Imperial head centre; the old
                    # 1.445 m proof offset left the cap below the scalp.
                    vertices = vertices + np.array([0.0, 1.565, -0.005])
                if cast == "imperial-guard" and "Shield" in material:
                    vertices = vertices + np.array([0.22, 0.91, -0.11])
                if relaxed_pose and not any(token in material for token in ("Head", "HR_", "Helmet")):
                    vertices, normals = relax_rest_geometry(vertices, normals)
                parts.append(
                    {
                        "name": f"{path.stem}_{primitive_index}",
                        "material": material,
                        "texture": material_texture(asset_root, material, female, cast),
                        "opacity": material_opacity(asset_root, material),
                        "surface": material_surface(asset_root, material, female, cast),
                        "vertices": vertices,
                        "normals": normals,
                        "texcoords": texcoords,
                        "faces": faces,
                    }
                )
    return parts


def trim_clothed_body(parts: list[dict]) -> list[dict]:
    """Remove hidden torso/leg skin that can poke through modular clothing.

    The underlying body is still retained for the neck, shoulders, arms, and
    hands.  Only central triangles covered by the shirt, trousers, and shoes
    are omitted; the clothing remains the authored outer surface.
    """
    result = []
    for part in parts:
        if "DarkElf_Body" not in part["material"]:
            result.append(part)
            continue
        clone = dict(part)
        centroids = part["vertices"][part["faces"]].mean(axis=1)
        covered = (centroids[:, 1] < 1.365) & (np.abs(centroids[:, 0]) < 0.245)
        clone["faces"] = part["faces"][~covered]
        result.append(clone)
    return result


def transformed(
    parts: list[dict],
    translation: np.ndarray,
    yaw_degrees: float,
    name: str,
    scale: float = 1.0,
) -> list[dict]:
    angle = math.radians(yaw_degrees)
    rotation = np.array(
        [[math.cos(angle), 0, math.sin(angle)], [0, 1, 0], [-math.sin(angle), 0, math.cos(angle)]],
        dtype=np.float64,
    )
    result = []
    for part in parts:
        clone = dict(part)
        clone["name"] = f"{name}_{part['name']}"
        clone["vertices"] = (rotation @ (part["vertices"] * scale).T).T + translation
        clone["normals"] = (rotation @ part["normals"].T).T
        result.append(clone)
    return result


def write_obj(path: pathlib.Path, parts: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mtl_path = path.with_suffix(".mtl")
    materials = {}
    for part in parts:
        materials[part["material"]] = (part["texture"], part["opacity"], part["surface"])

    with mtl_path.open("w", encoding="utf-8", newline="\n") as stream:
        for material, (texture, opacity, surface) in materials.items():
            ambient = " ".join(f"{value:.6g}" for value in surface["ambient"])
            diffuse = " ".join(f"{value:.6g}" for value in surface["diffuse"])
            specular = " ".join(f"{value:.6g}" for value in surface["specular"])
            stream.write(
                f"newmtl {material}\nKa {ambient}\nKd {diffuse}\n"
                f"Ks {specular}\nNs {surface['shininess']:.6g}\n"
            )
            if texture is not None and texture.exists():
                stream.write(f"map_Kd {texture.as_posix()}\n")
            if opacity is not None and opacity.exists():
                stream.write(f"map_d {opacity.as_posix()}\n")
            stream.write("\n")

    vertex_offset = 0
    texcoord_offset = 0
    normal_offset = 0
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(f"mtllib {mtl_path.name}\n")
        for part in parts:
            stream.write(f"o {part['name']}\nusemtl {part['material']}\n")
            for x, y, z in part["vertices"]:
                stream.write(f"v {x:.8g} {y:.8g} {z:.8g}\n")
            for u, v in part["texcoords"][:, :2]:
                stream.write(f"vt {u:.8g} {1.0 - v:.8g}\n")
            for x, y, z in part["normals"]:
                stream.write(f"vn {x:.8g} {y:.8g} {z:.8g}\n")
            for triangle in part["faces"]:
                refs = []
                for index in triangle:
                    vi = vertex_offset + int(index) + 1
                    ti = texcoord_offset + int(index) + 1
                    ni = normal_offset + int(index) + 1
                    refs.append(f"{vi}/{ti}/{ni}")
                stream.write("f " + " ".join(refs) + "\n")
            vertex_offset += len(part["vertices"])
            texcoord_offset += len(part["texcoords"])
            normal_offset += len(part["normals"])


def bake_masked_card_geometry(part: dict, subdivisions: int, threshold: float = 0.24) -> dict:
    """Turn a masked hair-card primitive into explicit cutout triangles."""
    opacity_path = part.get("opacity")
    if opacity_path is None or not opacity_path.exists():
        return part

    mask = np.asarray(Image.open(opacity_path).convert("L"), dtype=np.uint8)
    height, width = mask.shape

    def barycentric(i: int, j: int) -> np.ndarray:
        return np.array(
            [1.0 - (i + j) / subdivisions, i / subdivisions, j / subdivisions],
            dtype=np.float64,
        )

    micro_triangles = []
    for i in range(subdivisions):
        for j in range(subdivisions - i):
            a = barycentric(i, j)
            b = barycentric(i + 1, j)
            c = barycentric(i, j + 1)
            micro_triangles.append(np.stack((a, b, c)))
            if j < subdivisions - i - 1:
                d = barycentric(i + 1, j + 1)
                micro_triangles.append(np.stack((b, d, c)))
    bary = np.stack(micro_triangles)

    vertices_out = []
    normals_out = []
    texcoords_out = []
    cutoff = int(round(threshold * 255.0))
    for face in part["faces"]:
        face_vertices = part["vertices"][face]
        face_normals = part["normals"][face]
        face_texcoords = part["texcoords"][face]
        micro_texcoords = bary @ face_texcoords
        centres = micro_texcoords[:, :, :2].mean(axis=1)
        sample_x = np.clip(np.rint(centres[:, 0] * (width - 1)), 0, width - 1).astype(np.int64)
        sample_y = np.clip(np.rint(centres[:, 1] * (height - 1)), 0, height - 1).astype(np.int64)
        keep = mask[sample_y, sample_x] >= cutoff
        if not np.any(keep):
            continue
        vertices_out.append((bary[keep] @ face_vertices).reshape(-1, 3))
        normals = (bary[keep] @ face_normals).reshape(-1, 3)
        lengths = np.linalg.norm(normals, axis=1)
        normals = np.divide(
            normals,
            lengths[:, None],
            out=np.zeros_like(normals),
            where=lengths[:, None] > 0,
        )
        normals_out.append(normals)
        texcoords_out.append(micro_texcoords[keep].reshape(-1, face_texcoords.shape[1]))

    result = dict(part)
    if not vertices_out:
        result["vertices"] = np.empty((0, 3), dtype=np.float64)
        result["normals"] = np.empty((0, 3), dtype=np.float64)
        result["texcoords"] = np.empty((0, part["texcoords"].shape[1]), dtype=np.float64)
        result["faces"] = np.empty((0, 3), dtype=np.int64)
    else:
        result["vertices"] = np.concatenate(vertices_out, axis=0)
        result["normals"] = np.concatenate(normals_out, axis=0)
        result["texcoords"] = np.concatenate(texcoords_out, axis=0)
        result["faces"] = np.arange(len(result["vertices"]), dtype=np.int64).reshape(-1, 3)
    # The mask is now represented by geometry, so do not ask osgdb_dae to
    # interpret the same texture as whole-surface transparency.
    result["opacity"] = None
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-root", required=True, type=pathlib.Path)
    parser.add_argument("--animation", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--cast", choices=("aleswell", "imperial-waterfront"), default="aleswell")
    parser.add_argument(
        "--placement",
        choices=("remastered-south-plaza", "classic-waterfront-overlay"),
        default="remastered-south-plaza",
    )
    parser.add_argument("--civilian-asset-root", type=pathlib.Path)
    parser.add_argument("--frame", type=int, default=90)
    parser.add_argument("--rest-pose", action="store_true")
    parser.add_argument("--jaw-close-degrees", type=float, default=0.0)
    parser.add_argument("--morph", action="append", default=[], metavar="NAME=WEIGHT")
    parser.add_argument("--hide-teeth", action="store_true")
    parser.add_argument("--close-mouth", action="store_true")
    parser.add_argument("--hide-hair", action="store_true")
    parser.add_argument("--hide-helmet-fur", action="store_true")
    parser.add_argument("--bake-masked-cards", action="store_true")
    parser.add_argument("--solid-helmet-crest", action="store_true")
    args = parser.parse_args()

    # COLLADA resolves image paths relative to the exported scene.  Keep the
    # proprietary, user-local source textures as absolute file references so
    # an invocation from the repository root cannot silently turn them into
    # scene-relative paths during the OBJ -> DAE bridge.
    args.asset_root = args.asset_root.resolve()
    args.output = args.output.resolve()
    if args.civilian_asset_root is not None:
        args.civilian_asset_root = args.civilian_asset_root.resolve()
    if args.animation is not None:
        args.animation = args.animation.resolve()

    if not args.rest_pose and args.animation is None:
        parser.error("--animation is required unless --rest-pose is used")
    source_animation = {} if args.rest_pose else parse_psa_frame(args.animation, args.frame)
    if args.cast == "imperial-waterfront" and source_animation:
        reference = (
            args.asset_root
            / "OblivionRemastered"
            / "Content"
            / "Art"
            / "Armor"
            / "ImperialPalace"
            / "SK_ImperialPalace_Cuirass_m.glb"
        )
        animation = retarget_idle_limbs(reference, source_animation)
    else:
        animation = source_animation
    if args.cast == "aleswell":
        animation.update(neutral_face_overrides(args.asset_root, args.jaw_close_degrees))
    morph_weights = {}
    for value in args.morph:
        name, separator, weight = value.partition("=")
        if not separator:
            raise ValueError(f"Morph must be NAME=WEIGHT: {value}")
        morph_weights[name] = float(weight)
    if args.cast == "imperial-waterfront":
        if args.civilian_asset_root is None:
            parser.error("--civilian-asset-root is required for the imperial-waterfront cast")
        guard = bake_actor(
            args.asset_root,
            False,
            "short",
            {},
            morph_weights,
            args.hide_teeth,
            args.close_mouth,
            "imperial-guard",
            True,
        )
        if args.hide_helmet_fur:
            guard = [part for part in guard if "Legion_Helmet_Fur" not in part["material"]]
        if args.solid_helmet_crest:
            for part in guard:
                if "Legion_Helmet_Fur" in part["material"]:
                    part["opacity"] = None
        civilian = bake_actor(
            args.civilian_asset_root,
            False,
            "short",
            {},
            morph_weights,
            args.hide_teeth,
            args.close_mouth,
            "aleswell",
            True,
        )
        civilian = trim_clothed_body(civilian)
        if args.hide_hair:
            civilian = [part for part in civilian if "HR_" not in part["material"]]
        if args.bake_masked_cards:
            guard = [
                bake_masked_card_geometry(part, 4, 0.10)
                if "Legion_Helmet_Fur" in part["material"]
                else part
                for part in guard
            ]
            civilian = [
                bake_masked_card_geometry(part, 3) if "HR_" in part["material"] else part
                for part in civilian
            ]

        # UE World Partition coordinates for the Imperial City Waterfront
        # plaza are (27980.64, -68031.36, 365.76) centimetres.  The exported
        # scene and this cast share Y-up metre coordinates before OSG import.
        actors = []
        if args.placement == "classic-waterfront-overlay":
            # World-space metre coordinates for the recovered classic proof.
            # The OpenMW foreground loader maps source (X, Y, Z) to runtime
            # (X, -Z, Y), so these marks reproduce the original player, day
            # guard and night guard positions with a scale of 100 and no offset.
            # Remastered actors are authored roughly 1.4x taller than the
            # classic on-screen cast at this lens.  Scale each mesh about its
            # own placement root so the world marks stay fixed.  The civilian
            # faces the same screen-right profile as the classic player.
            actors += transformed(
                civilian, np.array([193.338, 2.730, -469.258]), 90, "WaterfrontCivilian", 0.70
            )
            actors += transformed(
                guard, np.array([194.466, 2.689, -469.294]), 130, "WaterfrontGuardA", 0.70
            )
            actors += transformed(
                guard, np.array([194.761, 2.707, -470.037]), 130, "WaterfrontGuardB", 0.70
            )
        else:
            # The Remastered tower is substantially wider than the classic
            # shell. These points are vertical ray hits on the exported south
            # plaza, past the new tower footprint and on authored paving.
            actors += transformed(civilian, np.array([276.200, 3.914, -691.000]), 5, "WaterfrontCivilian")
            actors += transformed(guard, np.array([275.000, 3.841, -690.000]), 0, "WaterfrontGuardA")
            actors += transformed(guard, np.array([274.700, 3.842, -690.000]), 8, "WaterfrontGuardB")
        write_obj(args.output, actors)
        all_vertices = np.concatenate([part["vertices"] for part in actors], axis=0)
        print(
            json.dumps(
                {
                    "output": str(args.output.resolve()),
                    "cast": args.cast,
                    "placement": args.placement,
                    "frame": "relaxed-bind",
                    "retargetedIdleBones": [],
                    "actors": 3,
                    "parts": len(actors),
                    "vertices": int(sum(len(part["vertices"]) for part in actors)),
                    "triangles": int(sum(len(part["faces"]) for part in actors)),
                    "boundsMin": all_vertices.min(axis=0).tolist(),
                    "boundsMax": all_vertices.max(axis=0).tolist(),
                },
                indent=2,
            )
        )
        return 0

    male = bake_actor(args.asset_root, False, "short", animation, morph_weights, args.hide_teeth, args.close_mouth)
    female_bob = bake_actor(
        args.asset_root, True, "bob", animation, morph_weights, args.hide_teeth, args.close_mouth
    )
    female_short = bake_actor(
        args.asset_root, True, "short", animation, morph_weights, args.hide_teeth, args.close_mouth
    )
    if args.hide_hair:
        male = [part for part in male if "HR_" not in part["material"]]
        female_bob = [part for part in female_bob if "HR_" not in part["material"]]
        female_short = [part for part in female_short if "HR_" not in part["material"]]

    # Source coordinates are Y-up metres.  These are the three native Aleswell
    # placements transformed through the same scene alignment as the room.
    actors = []
    # Preserve the native placements but turn the proof cast toward the close
    # camera so face and hair quality can be judged in a single frame.
    actors += transformed(female_bob, np.array([34.1405, 85.6472, -31.0554]), 136, "Urnsi")
    actors += transformed(female_short, np.array([34.8450, 85.6472, -29.6099]), 111, "Adosi")
    actors += transformed(male, np.array([32.3483, 85.6472, -30.3559]), 158, "Diram")
    write_obj(args.output, actors)

    all_vertices = np.concatenate([part["vertices"] for part in actors], axis=0)
    print(
        json.dumps(
            {
                "output": str(args.output.resolve()),
                "frame": "rest" if args.rest_pose else args.frame,
                "jawCloseDegrees": args.jaw_close_degrees,
                "morphs": morph_weights,
                "teethVisible": not args.hide_teeth,
                "mouthClosed": args.close_mouth,
                "hairVisible": not args.hide_hair,
                "actors": 3,
                "parts": len(actors),
                "vertices": int(sum(len(part["vertices"]) for part in actors)),
                "triangles": int(sum(len(part["faces"]) for part in actors)),
                "boundsMin": all_vertices.min(axis=0).tolist(),
                "boundsMax": all_vertices.max(axis=0).tolist(),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
