#!/usr/bin/env python3
"""Build the local PNG texture cache used by the Starfield compatibility path.

Starfield's BC7 DDS assets are not currently decoded by this OpenMW build.
This bounded, idempotent bridge reads texture paths from the authored material
map plus the actor proof defaults, extracts only those files from the user's
installed BA2 archives, and converts them to PNG in the profile's data-local
directory.  It never launches Starfield or controls a window/input device.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
from pathlib import Path


ACTOR_TEXTURES = (
    "textures/actors/human/faces/chargen/male_default_sk3_color.dds",
    "textures/actors/human/faces/chargen/female_default_sk3_color.dds",
    "textures/actors/human/faces/beards/beard_shared_brown_color.dds",
    "textures/actors/human/faces/hair/afro_hair_shared_brown_color.dds",
    "textures/actors/human/faces/hair/short_hair_shared_brown_color.dds",
    "textures/actors/human/faces/eyebrows/eyebrows_fluffy_brown_color.dds",
    "textures/actors/human/faces/eyebrows/femaleeyebrows01_color.dds",
    "textures/actors/human/faces/eyelashes/malelashes01_color.dds",
    "textures/actors/human/faces/eyelashes/femalelashes01_color.dds",
    "textures/actors/human/faces/eyes/eye_tear_color.dds",
    "textures/actors/human/faces/teeth/nnteeth_color.dds",
    "textures/actors/human/naked_body/nakedbodym_sk3_color.dds",
    "textures/actors/human/naked_body/nakedbodyf_sk3_color.dds",
    "textures/actors/human/hands/defaulthandsm_sk3_color.dds",
    "textures/actors/human/hands/defaulthandsf_sk3_color.dds",
    "textures/clothes/outfit_miner_utililtysuit/outfit_miner_utilitysuit_m/outfit_miner_utilitysuit_pants_m_color.dds",
    "textures/clothes/outfit_miner_utililtysuit/outfit_miner_utilitysuit_m/outfit_miner_utilitysuit_shirt_materials_color.dds",
    "textures/clothes/outfit_miner_utililtysuit/outfit_miner_utilitysuit_m/outfit_miner_utilitysuit_sleeves_lod0_m_color.dds",
    "textures/clothes/outfit_service_uniform_01/outfit_service_uniform_lowerbody_01_color.dds",
    "textures/clothes/outfit_service_uniform_01/outfit_service_uniform_sleeves_01_color.dds",
    "textures/clothes/outfit_service_uniform_01/outfit_service_uniform_upperbody_01_color.dds",
    "textures/clothes/outfit_employee_uniform_formal_01/outfit_employee_uniform_formal_lowerbody_01_color.dds",
    "textures/clothes/outfit_employee_uniform_formal_01/outfit_employee_uniform_formal_sleeves_01_color.dds",
    "textures/clothes/outfit_employee_uniform_formal_01/outfit_employee_uniform_formal_upperbody_01_color.dds",
    "textures/clothes/outfit_ucpolice/outfit_ucsecurity_arms_mat_color.dds",
    "textures/clothes/outfit_ucpolice/outfit_ucsecurity_helmet_mat_color.dds",
    "textures/clothes/outfit_ucpolice/outfit_ucsecurity_legsandacc_mat_color.dds",
    "textures/clothes/outfit_ucpolice/outfit_ucsecurity_torso_mat_color.dds",
    "textures/clothes/outfit_ucpolice/outfit_ucsecurity_visor_mat_color.dds",
    "textures/clothes/spacesuit_ecliptic/spacesuit_ecliptic_flightcap_color.dds",
    "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_hat_color.dds",
    "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_sleeves_color.dds",
    "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_upperbody_color.dds",
    "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_f/outfit_colonist_quarterpaddedvest_01_lowerbody_f_color.dds",
    "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_m/outfit_colonist_quarterpaddedvest_01_lowerbody_m_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_mechanic_lowerbody_01_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_mechanic_sleeves_01_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_mechanic_upperbody_01_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/headwear_ssohat_01_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_sso_jacket_sleeves_01_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_sso_jacket_upperbody_01_color.dds",
    "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_sso_jacket_cooling_upperbody_01_color.dds",
)


def normalized(value: str) -> str:
    value = value.strip().strip('"').replace("\\", "/")
    if value.lower().startswith("data/"):
        value = value[5:]
    return value.lower()


def read_profile_paths(path: Path) -> tuple[list[Path], Path | None]:
    data_dirs: list[Path] = []
    data_local: Path | None = None
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"')
        if key.strip().lower() == "data":
            candidate = Path(value).expanduser()
            if candidate.is_dir():
                data_dirs.append(candidate.resolve())
        elif key.strip().lower() == "data-local":
            data_local = Path(value).expanduser().resolve()
    return list(dict.fromkeys(data_dirs)), data_local


def read_material_textures(path: Path) -> list[str]:
    result: list[str] = []
    with path.open("r", encoding="utf-8", newline="") as stream:
        rows = (line for line in stream if line.strip() and not line.startswith("#"))
        for row in csv.reader(rows, delimiter="\t"):
            if len(row) >= 2:
                texture = normalized(row[1])
                if texture.startswith("textures/") and texture.endswith(".dds"):
                    result.append(texture)
    return result


def opacity_texture(texture: str) -> str | None:
    lower = texture.lower()
    if not lower.startswith(
        (
            "textures/actors/human/faces/hair/",
            "textures/actors/human/faces/beards/",
            "textures/actors/human/faces/eyebrows/",
        )
    ) or not lower.endswith("_color.dds"):
        return None
    directory, filename = lower.rsplit("/", 1)
    stem = filename.removesuffix(".dds")
    parts = stem.split("_")
    if "shared" in parts:
        shared_index = parts.index("shared")
        return f"{directory}/{'_'.join(parts[:shared_index + 1])}_opacity.dds"
    if stem.startswith("eyebrows_") and len(parts) >= 3:
        return f"{directory}/{'_'.join(parts[:-2])}_opacity.dds"
    return f"{directory}/{stem.removesuffix('_color')}_opacity.dds"


def find_archives(data_dirs: list[Path]) -> list[Path]:
    archives: list[Path] = []
    for directory in data_dirs:
        archives.extend(sorted(directory.glob("Starfield - Textures*.ba2")))
        archives.extend(sorted(directory.glob("Starfield - GeneratedTextures.ba2")))
    return list(dict.fromkeys(path.resolve() for path in archives))


def locate_sources(bsatool: Path, archives: list[Path], wanted: set[str]) -> dict[str, tuple[Path, str]]:
    found: dict[str, tuple[Path, str]] = {}
    for archive in archives:
        if len(found) == len(wanted):
            break
        process = subprocess.Popen(
            [str(bsatool), "list", str(archive)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="ignore",
        )
        assert process.stdout is not None
        for raw_line in process.stdout:
            listed = raw_line.strip().replace("\\", "/")
            key = normalized(listed)
            if key in wanted and key not in found:
                found[key] = (archive, listed)
        return_code = process.wait()
        if return_code != 0:
            raise RuntimeError(f"bsatool failed while listing {archive} (exit {return_code})")
    return found


def safe_destination(root: Path, texture: str, suffix: str) -> Path:
    relative = Path(texture).with_suffix(suffix)
    destination = (root / relative).resolve()
    try:
        destination.relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"texture escaped cache root: {texture}") from exc
    return destination


def extract_texture(bsatool: Path, source: tuple[Path, str], extract_root: Path) -> Path:
    archive, listed_path = source
    subprocess.run(
        [str(bsatool), "extract", "-f", str(archive), listed_path, str(extract_root)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    extracted = extract_root.joinpath(*listed_path.replace("\\", "/").split("/"))
    if extracted.is_file():
        return extracted
    # Windows Path('/') replacement above is intentionally platform-native,
    # but bsatool can preserve archive casing.  Fall back to a bounded suffix
    # lookup when the exact spelling differs.
    filename = Path(listed_path).name.lower()
    matches = [path for path in extract_root.rglob("*") if path.is_file() and path.name.lower() == filename]
    if len(matches) != 1:
        raise FileNotFoundError(f"unable to locate extracted {listed_path}")
    return matches[0]


def convert_dds(source: Path, destination: Path, ffmpeg: str | None) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        from PIL import Image

        with Image.open(source) as image:
            image.load()
            image.convert("RGBA").save(destination)
        return "pillow"
    except Exception as pillow_error:
        if ffmpeg is None:
            raise RuntimeError(f"Pillow could not decode {source}: {pillow_error}") from pillow_error
        subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
             "-frames:v", "1", "-update", "1", str(destination)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        return "ffmpeg"


def merge_opacity(color_png: Path, opacity_dds: Path, ffmpeg: str | None, temp_root: Path) -> int:
    from PIL import Image

    opacity_png = temp_root / (opacity_dds.stem + "-opacity.png")
    convert_dds(opacity_dds, opacity_png, ffmpeg)
    with Image.open(color_png) as color_source, Image.open(opacity_png) as opacity_source:
        color = color_source.convert("RGBA")
        opacity = opacity_source.convert("L")
        if opacity.size != color.size:
            opacity = opacity.resize(color.size, Image.Resampling.LANCZOS)
        color.putalpha(opacity)
        color.save(color_png)
        histogram = opacity.histogram()
        return sum(histogram[:255])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openmw-cfg", type=Path, required=True)
    parser.add_argument("--material-map", type=Path, required=True)
    parser.add_argument("--data-local", type=Path)
    parser.add_argument("--binary-root", type=Path, required=True)
    parser.add_argument("--ledger", type=Path)
    args = parser.parse_args()

    data_dirs, configured_data_local = read_profile_paths(args.openmw_cfg)
    data_local = (args.data_local or configured_data_local)
    if data_local is None:
        parser.error("no data-local path was supplied or found in openmw.cfg")
    data_local = data_local.resolve()
    data_local.mkdir(parents=True, exist_ok=True)
    bsatool = (args.binary_root / "bsatool.exe").resolve()
    if not bsatool.is_file():
        parser.error(f"missing bsatool: {bsatool}")

    textures = sorted(set(normalized(value) for value in ACTOR_TEXTURES) | set(read_material_textures(args.material_map)))
    ledger: list[dict[str, object]] = []
    missing_main: set[str] = set()
    for texture in textures:
        destination = safe_destination(data_local, texture, ".png")
        if destination.is_file():
            ledger.append({"texture": texture, "png": str(destination), "status": "already-cached"})
        else:
            missing_main.add(texture)

    opacity_by_color = {
        texture: opacity
        for texture in missing_main
        if (opacity := opacity_texture(texture)) is not None
    }
    wanted = set(missing_main) | set(opacity_by_color.values())
    archives = find_archives(data_dirs)
    if wanted and not archives:
        parser.error("no Starfield texture BA2 archives were found in configured data directories")
    sources = locate_sources(bsatool, archives, wanted) if wanted else {}
    ffmpeg = shutil.which("ffmpeg")
    extract_root = data_local / "__starfield_texture_extract"
    shutil.rmtree(extract_root, ignore_errors=True)
    extract_root.mkdir(parents=True, exist_ok=True)
    extracted_cache: dict[str, Path] = {}

    def extracted(texture: str) -> Path:
        if texture not in extracted_cache:
            source = sources.get(texture)
            if source is None:
                raise FileNotFoundError(f"texture is not present in configured Starfield BA2s: {texture}")
            extracted_cache[texture] = extract_texture(bsatool, source, extract_root)
        return extracted_cache[texture]

    converted = 0
    opacity_merged = 0
    non_opaque_pixels = 0
    try:
        for texture in sorted(missing_main):
            destination = safe_destination(data_local, texture, ".png")
            try:
                decoder = convert_dds(extracted(texture), destination, ffmpeg)
                opacity = opacity_by_color.get(texture)
                alpha_pixels = 0
                if opacity is not None and opacity in sources:
                    alpha_pixels = merge_opacity(destination, extracted(opacity), ffmpeg, extract_root)
                    opacity_merged += 1
                    non_opaque_pixels += alpha_pixels
                converted += 1
                ledger.append(
                    {
                        "texture": texture,
                        "png": str(destination),
                        "archive": str(sources[texture][0]),
                        "status": "converted",
                        "decoder": decoder,
                        "opacityTexture": opacity,
                        "alphaNonOpaquePixels": alpha_pixels,
                    }
                )
            except Exception as exc:
                destination.unlink(missing_ok=True)
                ledger.append({"texture": texture, "status": "failed", "error": str(exc)})
    finally:
        shutil.rmtree(extract_root, ignore_errors=True)

    ledger_path = (args.ledger or (data_local / "starfield-texture-cache-ledger.json")).resolve()
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    failed = [item for item in ledger if item["status"] == "failed"]
    payload = {
        "schemaVersion": 1,
        "materialMap": str(args.material_map.resolve()),
        "dataLocal": str(data_local),
        "requested": len(textures),
        "converted": converted,
        "alreadyCached": sum(item["status"] == "already-cached" for item in ledger),
        "failed": len(failed),
        "opacityMerged": opacity_merged,
        "alphaNonOpaquePixels": non_opaque_pixels,
        "entries": sorted(ledger, key=lambda item: str(item["texture"])),
    }
    ledger_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(
        f"requested={payload['requested']} converted={converted} "
        f"alreadyCached={payload['alreadyCached']} failed={len(failed)} ledger={ledger_path}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(f"cache initialization failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
