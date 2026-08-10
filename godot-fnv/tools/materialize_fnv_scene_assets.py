#!/usr/bin/env python3
"""Extract and convert missing static assets required by a compact scene pack."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
from pathlib import Path


SKIP_PREFIXES = (
    "effects/",
    "characters/",
    "creatures/",
    "marker",
    "furniture/floorsitmarker",
    "furniture/wallmarker",
)


def canonical(value: str) -> str:
    return value.replace("/", "\\").lstrip("\\").lower()


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, check=check)


def archive_index(bsatool: Path, archive: Path) -> set[str]:
    result = run([str(bsatool), "list", str(archive)])
    return {canonical(line.strip()) for line in result.stdout.splitlines() if line.strip()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--bsatool", type=Path, required=True)
    parser.add_argument("--mesh-bsa", type=Path, required=True)
    parser.add_argument("--texture-bsa", type=Path, action="append", required=True)
    parser.add_argument("--native-root", type=Path, required=True)
    parser.add_argument("--converted-root", type=Path, required=True)
    parser.add_argument("--converter", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    candidates: list[str] = []
    for asset in manifest.get("assets", []):
        model = canonical(str(asset["source_path"]))
        output = args.converted_root / Path(model[:-4].replace("\\", "/") + ".obj")
        if output.exists() or model.startswith(SKIP_PREFIXES) or model.endswith("skeleton.nif"):
            continue
        candidates.append(model)

    dependency_root = args.manifest.parent / "asset-dependencies"
    dependency_root.mkdir(parents=True, exist_ok=True)
    textures: set[str] = set()
    converted = 0
    failed: list[dict[str, str]] = []

    def materialize_model(model: str) -> tuple[str, str, set[str]]:
        archive_path = "meshes\\" + model
        native = args.native_root / Path(archive_path.replace("\\", "/"))
        output = args.converted_root / Path(model[:-4].replace("\\", "/") + ".obj")
        deps = dependency_root / (model.replace("\\", "__") + ".json")
        if not native.exists():
            extracted = run(
                [str(args.bsatool), "extract", "-f", str(args.mesh_bsa), archive_path, str(args.native_root)],
                check=False,
            )
            if extracted.returncode != 0 or not native.exists():
                return model, "extract", set()
        output.parent.mkdir(parents=True, exist_ok=True)
        result = run(
            [
                sys.executable,
                str(args.converter),
                "--input",
                str(native),
                "--output",
                str(output),
                "--texture-root",
                str(args.converted_root),
                "--dependencies-output",
                str(deps),
            ],
            check=False,
        )
        if result.returncode != 0 or not output.exists():
            return model, "convert", set()
        model_textures: set[str] = set()
        if deps.exists():
            model_textures.update(canonical(row) for row in json.loads(deps.read_text()).get("textures", []))
        return model, "ok", model_textures

    # Extraction and NIF conversion are independent per source model. A small
    # worker pool keeps the one-time complete-world materialization from taking
    # tens of minutes while avoiding excessive contention on the BSA archive.
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        for model, status, model_textures in executor.map(materialize_model, candidates):
            if status == "ok":
                converted += 1
                textures.update(model_textures)
            else:
                failed.append({"model": model, "stage": status})

    indices = [(archive, archive_index(args.bsatool, archive)) for archive in args.texture_bsa]
    extracted_textures = 0
    missing_textures: list[str] = []
    for texture in sorted(textures):
        output = args.converted_root / Path(texture.replace("\\", "/"))
        if output.exists():
            continue
        archive = next((path for path, rows in indices if texture in rows), None)
        if archive is None:
            missing_textures.append(texture)
            continue
        output.parent.mkdir(parents=True, exist_ok=True)
        result = run(
            [str(args.bsatool), "extract", "-f", str(archive), texture, str(args.converted_root)], check=False
        )
        if result.returncode == 0 and output.exists():
            extracted_textures += 1
        else:
            missing_textures.append(texture)

    report = {
        "schema": "nikami-fnv-scene-asset-materialization/v1",
        "candidate_models": len(candidates),
        "converted_models": converted,
        "failed_models": failed,
        "referenced_textures": len(textures),
        "extracted_textures": extracted_textures,
        "missing_textures": missing_textures,
    }
    report_path = args.manifest.parent / "scene-asset-materialization.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("OPENNV_SCENE_ASSETS " + json.dumps({k: report[k] for k in (
        "candidate_models", "converted_models", "referenced_textures", "extracted_textures"
    )}, sort_keys=True))
    print(f"OPENNV_SCENE_ASSETS_REPORT {report_path}")
    return 0 if not failed else 2


if __name__ == "__main__":
    raise SystemExit(main())
