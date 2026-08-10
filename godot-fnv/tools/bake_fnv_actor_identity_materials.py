#!/usr/bin/env python3
"""Bake FNV's authored FaceGen skin inputs into Godot actor snapshot albedo.

The OpenNV actor OBJ cache already contains the post-skin, post-FGGS/FGGA
geometry emitted by the live OpenMW actor. OBJ/MTL can retain only texture unit
zero, however, so FNV's FaceGen0/FaceGen1 complexion inputs were being lost.
This tool applies the retail SKIN2002 composition to the affected head diffuse
and records the retained identity inputs in the runtime actor manifest.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path

import numpy as np
from PIL import Image


TARGET_BASES = {
    "0x00104c7f": "easy-pete",
    "0x0010c767": "arcade-gannon",
    "0x00131f77": "vulpes-inculta",
}
HEAD_DIFFUSE = re.compile(r"textures[/\\]characters[/\\](?:male|female)[/\\]head[^/\\]*\.dds$", re.I)
MAP_KD = re.compile(r"^(\s*map_Kd\s+)(.+?)\s*$", re.I)


def canonical_form(value: str) -> str:
    return f"0x{int(value, 16):08x}"


def resource_to_path(project_root: Path, value: str) -> Path:
    if not value.startswith("res://"):
        raise ValueError(f"Expected Godot resource path, got {value}")
    return project_root / value[6:]


def bake_face(base: Image.Image, detail: Image.Image) -> Image.Image:
    base_rgba = np.asarray(base.convert("RGBA"), dtype=np.float32) / 255.0
    detail_rgb = np.asarray(
        detail.convert("RGB").resize(base.size, Image.Resampling.LANCZOS), dtype=np.float32
    ) / 255.0
    # Exact FNV SKIN2002 composition used by the maintained OpenNV renderer:
    # (base + 2 * (FaceGen0 - 0.5)) * (4 * FaceGen1).
    face_gen_1 = np.asarray([62.0, 65.0, 62.0], dtype=np.float32) / 255.0
    rgb = (base_rgba[..., :3] + 2.0 * (detail_rgb - 0.5)) * (4.0 * face_gen_1)
    output = np.empty_like(base_rgba)
    output[..., :3] = np.clip(rgb, 0.0, 1.0)
    output[..., 3] = base_rgba[..., 3]
    return Image.fromarray(np.rint(output * 255.0).astype(np.uint8), "RGBA")


def patch_material(mtl_path: Path, output_texture: Path, project_root: Path) -> str:
    lines = mtl_path.read_text(encoding="utf-8").splitlines()
    replacement = os.path.relpath(output_texture, mtl_path.parent).replace("\\", "/")
    found_source = ""
    patched = False
    output: list[str] = []
    for line in lines:
        match = MAP_KD.match(line)
        if match and HEAD_DIFFUSE.search(match.group(2).replace("\\", "/")):
            found_source = match.group(2)
            output.append(f"# OPENNV_FACEGEN_SOURCE {found_source}")
            output.append(match.group(1) + replacement)
            patched = True
        else:
            output.append(line)
    if not patched:
        existing = any("OPENNV_FACEGEN_SOURCE" in line for line in lines)
        if not existing:
            raise RuntimeError(f"No humanoid head diffuse found in {mtl_path}")
    mtl_path.write_text("\n".join(output) + "\n", encoding="utf-8", newline="\n")
    return found_source


def suppress_victor_cover_surfaces(obj_path: Path) -> int:
    lines = obj_path.read_text(encoding="utf-8").splitlines()
    output: list[str] = []
    suppressed = False
    removed_faces = 0
    for line in lines:
        if line.startswith("g actor_surface_"):
            surface = line.removeprefix("g actor_surface_").strip()
            suppressed = surface in {"0", "2"}  # white noise and glare cover the authored face
            output.append(line)
        elif suppressed and line.startswith("f "):
            removed_faces += 1
        else:
            output.append(line)
    if removed_faces == 0 and "OPENNV_VICTOR_SCREEN_COVERS_REMOVED" not in "\n".join(lines[:8]):
        raise RuntimeError(f"Victor cover surfaces were not found in {obj_path}")
    if "# OPENNV_VICTOR_SCREEN_COVERS_REMOVED" not in output[:8]:
        output.insert(1, "# OPENNV_VICTOR_SCREEN_COVERS_REMOVED")
    obj_path.write_text("\n".join(output) + "\n", encoding="utf-8", newline="\n")
    return removed_faces


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    manifest_path = args.manifest.resolve()
    converted = project_root / "generated" / "assets" / "converted"
    facegen_root = project_root / "generated" / "actors" / "identity-materials"
    facegen_root.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    baked: list[dict] = []

    for actor in manifest.get("actors", []):
        base = canonical_form(str(actor.get("base_form", "0")))
        if base not in TARGET_BASES:
            continue
        obj_path = resource_to_path(project_root, actor["mesh"])
        mtl_path = obj_path.with_suffix(".mtl")
        detail_path = converted / "textures" / "characters" / "facemods" / "falloutnv.esm" / f"{base[2:]}_0.dds"
        if not detail_path.is_file():
            raise FileNotFoundError(detail_path)
        lines = mtl_path.read_text(encoding="utf-8").splitlines()
        source_text = next(
            (MAP_KD.match(line).group(2) for line in lines if MAP_KD.match(line) and HEAD_DIFFUSE.search(MAP_KD.match(line).group(2).replace("\\", "/"))),
            None,
        )
        if source_text is None:
            source_marker = next((line.split(" ", 2)[2] for line in lines if line.startswith("# OPENNV_FACEGEN_SOURCE ")), None)
            source_text = source_marker
        if source_text is None:
            raise RuntimeError(f"Cannot recover head diffuse for {mtl_path}")
        source_path = (mtl_path.parent / source_text.replace("/", str(Path('/')))).resolve()
        if not source_path.is_file():
            raise FileNotFoundError(source_path)
        output_texture = facegen_root / f"{base[2:]}-{TARGET_BASES[base]}-facegen.png"
        bake_face(Image.open(source_path), Image.open(detail_path)).save(output_texture, optimize=True)
        patch_material(mtl_path, output_texture, project_root)
        actor["appearance"] = {
            "status": "facegen-baked",
            "race_and_npc_morph_geometry": "post-skin snapshot includes sex-specific race FGGS/FGGA baseline plus NPC FGGS/FGGA",
            "facegen0": "res://" + detail_path.relative_to(project_root).as_posix(),
            "facegen1_rgba": [62, 65, 62, 64],
            "composition": "(diffuse + 2*(FaceGen0-0.5)) * (4*FaceGen1)",
            "baked_albedo": "res://" + output_texture.relative_to(project_root).as_posix(),
        }
        baked.append({"actor": actor["id"], "base": base, "texture": str(output_texture)})

    victor_faces = 0
    for actor in manifest.get("actors", []):
        if canonical_form(str(actor.get("base_form", "0"))) != "0x00103dfd":
            continue
        if canonical_form(str(actor.get("authored_ref", "0"))) != "0x001073e8":
            continue
        victor_faces += suppress_victor_cover_surfaces(resource_to_path(project_root, actor["mesh"]))
        actor["appearance"] = {
            "status": "authored-securitron-screen",
            "screen_diffuse": "textures/creatures/securitron/victor_neutral.dds",
            "suppressed_static_cover_surfaces": ["whitenoise01", "screenglare"],
            "retained_rig_snapshot": True,
        }

    if len(baked) != 3 or victor_faces == 0:
        raise RuntimeError(f"Identity material acceptance failed: humans={len(baked)} victorFaces={victor_faces}")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    report = {"status": "pass", "humans": baked, "victor_removed_cover_faces": victor_faces}
    print("OPENNV_ACTOR_IDENTITY_MATERIALS " + json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
