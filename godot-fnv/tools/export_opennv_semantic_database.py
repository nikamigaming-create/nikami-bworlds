#!/usr/bin/env python3
"""Compile master-aware winning world and actor semantics for OpenNV Godot."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import sys
from collections import defaultdict
from pathlib import Path


REC_DELETED = 0x20
PLACED_TYPES = {"REFR", "ACHR", "ACRE", "PGRE", "PHZD"}


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _compact(value):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key.startswith("openmw") or key == "matches":
                continue
            cleaned = _compact(item)
            if cleaned is None or cleaned == "" or cleaned == [] or cleaned == {}:
                continue
            result[key] = cleaned
        return result
    if isinstance(value, list):
        return [_compact(item) for item in value]
    return value


def _encoded(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def compile_semantics(*, bootstrap_path: Path, data_root: Path, resolved_manifest_path: Path, output_dir: Path) -> dict:
    repo_root = Path(__file__).resolve().parents[2]
    corpus = _load(repo_root / "scripts" / "export_fnv_parity_corpus.py", "opennv_semantic_corpus")
    catalog_module = _load(repo_root / "scripts" / "export_esm4_catalog.py", "opennv_semantic_catalog")
    bootstrap = json.loads(bootstrap_path.read_text(encoding="utf-8"))
    resolved_manifest = json.loads(resolved_manifest_path.read_text(encoding="utf-8"))
    load_order = [str(value) for value in bootstrap["load_order"]]
    plugin_paths = [(data_root / name).resolve() for name in load_order]
    sources = corpus.inspect_plugins(plugin_paths)
    by_name = {source.name.casefold(): source for source in sources}
    if [source.name for source in sources] != load_order:
        raise RuntimeError("semantic plugin order differs from bootstrap")
    if [row["name"] for row in resolved_manifest["plugins"]] != load_order:
        raise RuntimeError("resolved-record database uses a different load order")
    for source, expected in zip(sources, resolved_manifest["plugins"], strict=True):
        if source.sha256 != expected["sha256"]:
            raise RuntimeError(f"plugin changed after resolved-record compile: {source.name}")

    winning_records: dict[int, dict] = {}
    winning_worlds: dict[int, dict] = {}
    winning_cells: dict[int, dict] = {}
    winning_placements: dict[int, dict] = {}
    for source in sources:
        master_indices = corpus._master_indices(source, by_name)
        allowed_unresolvable_raw = {
            entry[3] for entry in corpus.ALLOWED_UNRESOLVABLE_FORM_IDS
            if entry[0] == source.sha256
        }

        def resolver(raw: int, source=source, master_indices=master_indices,
                     allowed_unresolvable_raw=allowed_unresolvable_raw):
            try:
                return corpus._resolve_form_id(raw, source, master_indices, "semantic payload")
            except corpus.CorpusError:
                # The parity compiler owns a byte-identity-locked allowlist for
                # one malformed retail GRA reference. Keep it out of semantic
                # winner sets; never generalize recovery to arbitrary records.
                if raw in allowed_unresolvable_raw:
                    return None
                raise

        catalog = catalog_module.ESM4Catalog(
            source.path, mod_index=source.load_index, terms=[], form_resolver=resolver)
        catalog.parse()
        for form_id, record in catalog.records.items():
            row = _compact(record)
            row["sourcePlugin"] = source.name
            row["sourceIndex"] = source.load_index
            winning_records[form_id] = row
        for form_id, world in catalog.worlds.items():
            row = _compact(world)
            row["sourcePlugin"] = source.name
            winning_worlds[form_id] = row
        for form_id, cell in catalog.cells.items():
            row = _compact(cell)
            row["sourcePlugin"] = source.name
            winning_cells[form_id] = row
        for placement in catalog.placements:
            form_id = int(placement["id"], 16)
            row = _compact(placement)
            row["sourcePlugin"] = source.name
            row["sourceIndex"] = source.load_index
            winning_placements[form_id] = row

    live_records = {
        form_id: row for form_id, row in winning_records.items()
        if not (int(row.get("recordFlags", 0)) & REC_DELETED)
    }
    live_worlds = {form_id: row for form_id, row in winning_worlds.items() if form_id in live_records}
    live_cells = {form_id: row for form_id, row in winning_cells.items() if form_id in live_records}
    live_placements = {
        form_id: row for form_id, row in winning_placements.items()
        if form_id in live_records and not (int(row.get("recordFlags", 0)) & REC_DELETED)
    }
    base_type = {form_id: row.get("type", "") for form_id, row in live_records.items()}

    # LAND stores LTEX FormIDs, not texture paths. Resolve LTEX -> ICON or
    # LTEX -> TXST -> TX00 once in the compiler so terrain baking/runtime never
    # has to guess through the record graph or fall back to a flat material.
    resolved_land_textures = 0
    unresolved_land_textures = 0
    for cell in live_cells.values():
        terrain = cell.get("land")
        if not isinstance(terrain, dict):
            continue
        for layer_key in ("baseTextures", "alphaTextures"):
            for layer in terrain.get(layer_key, []):
                if not isinstance(layer, dict) or not layer.get("texture"):
                    continue
                texture_id = int(str(layer["texture"]), 16)
                texture_record = live_records.get(texture_id, {})
                diffuse = str(texture_record.get("landTexture", "")).strip()
                texture_set = texture_record.get("textureSet")
                if not diffuse and texture_set:
                    texture_set_record = live_records.get(int(str(texture_set), 16), {})
                    diffuse = str(texture_set_record.get("diffuseTexture", "")).strip()
                if diffuse:
                    layer["diffuse"] = diffuse
                    resolved_land_textures += 1
                else:
                    unresolved_land_textures += 1
    for row in live_placements.values():
        base = row.get("base")
        row["baseType"] = base_type.get(int(base, 16), "") if base else ""

    # Persistent exterior references are authored beneath a worldspace's
    # persistent CELL (usually grid 0,0), regardless of their actual position.
    # Keep parentCell intact for record semantics and compile spatialCell for
    # streaming. At duplicate grid 0,0 prefer the LAND-bearing temporary CELL.
    exterior_grid: dict[tuple[str, int, int], dict] = {}
    for cell in live_cells.values():
        if not cell.get("isExterior") or not cell.get("parentWorld"):
            continue
        key = (str(cell["parentWorld"]), int(cell.get("x", 0)), int(cell.get("y", 0)))
        incumbent = exterior_grid.get(key)
        if incumbent is None or (cell.get("land") and not incumbent.get("land")):
            exterior_grid[key] = cell
    spatially_reassigned = 0
    unresolved_exterior_spatial_cells = 0
    for row in live_placements.values():
        parent_value = row.get("parentCell")
        parent = live_cells.get(int(parent_value, 16)) if parent_value else None
        if parent is None or not parent.get("isExterior"):
            row["spatialCell"] = parent_value
            continue
        world = str(parent.get("parentWorld", ""))
        row["parentWorld"] = world
        position = row.get("pos", [0.0, 0.0, 0.0])
        if len(position) < 2 or not world:
            unresolved_exterior_spatial_cells += 1
            row["spatialCell"] = parent_value
            continue
        key = (world, math.floor(float(position[0]) / 4096.0), math.floor(float(position[1]) / 4096.0))
        spatial = exterior_grid.get(key)
        if spatial is None:
            unresolved_exterior_spatial_cells += 1
            row["spatialCell"] = parent_value
            continue
        row["spatialCell"] = spatial["id"]
        if row["spatialCell"] != parent_value:
            spatially_reassigned += 1
    placement_base_ids = {
        int(row["base"], 16) for row in live_placements.values() if row.get("base")
    }
    placement_bases = [
        live_records[form_id] for form_id in sorted(placement_base_ids)
        if form_id in live_records
    ]

    output_dir.mkdir(parents=True, exist_ok=True)
    artifacts = []

    def write(relative: str, payload: object) -> None:
        path = output_dir / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        content = _encoded(payload)
        path.write_bytes(content)
        artifacts.append({"path": relative.replace("\\", "/"), "sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)})

    write("worlds.json", {"schema": "opennv-semantic-worlds/v1", "worlds": [live_worlds[key] for key in sorted(live_worlds)]})
    write("cells.json", {"schema": "opennv-semantic-cells/v1", "cells": [live_cells[key] for key in sorted(live_cells)]})
    actor_bases = [row for _, row in sorted(live_records.items()) if row.get("type") in ("NPC_", "CREA")]
    actor_lists = [row for _, row in sorted(live_records.items()) if row.get("type") in ("LVLN", "LVLC")]
    actor_packages = [row for _, row in sorted(live_records.items()) if row.get("type") == "PACK"]
    actor_placements = [row for _, row in sorted(live_placements.items()) if row.get("type") in ("ACHR", "ACRE")]
    all_navmeshes = [row for _, row in sorted(live_records.items()) if row.get("type") == "NAVM"]
    navmeshes = [row for row in all_navmeshes if row.get("navmeshData")]
    expected_navmeshes = int(resolved_manifest.get("types", {}).get("NAVM", {}).get("live", -1))
    if expected_navmeshes < 0 or len(all_navmeshes) != expected_navmeshes:
        raise RuntimeError(
            f"semantic NAVM winner census {len(all_navmeshes)} differs from resolved database {expected_navmeshes}"
        )
    if len(navmeshes) != len(all_navmeshes):
        missing = [row.get("id") for row in all_navmeshes if not row.get("navmeshData")]
        raise RuntimeError(f"{len(missing)} live NAVM records have no decoded topology: {missing[:20]}")
    navmesh_by_id = {str(row["id"]): row for row in navmeshes}
    navmesh_vertices = sum(len(row["navmeshData"].get("vertices", [])) for row in navmeshes)
    navmesh_triangles = sum(len(row["navmeshData"].get("triangles", [])) for row in navmeshes)
    invalid_navmesh_door_triangles = sum(
        int(row["navmeshData"].get("invalidDoorTriangleCount", 0)) for row in navmeshes
    )
    unresolved_navmesh_external_links = 0
    invalid_navmesh_external_triangles = 0
    for row in navmeshes:
        for link in row["navmeshData"].get("externalConnections", []):
            target = navmesh_by_id.get(str(link.get("navmesh")))
            if target is None:
                unresolved_navmesh_external_links += 1
                continue
            triangle = int(link.get("triangle", -1))
            if triangle < 0 or triangle >= len(target["navmeshData"].get("triangles", [])):
                invalid_navmesh_external_triangles += 1
    write("actor-bases.json", {"schema": "opennv-semantic-actor-bases/v1", "actors": actor_bases})
    write("actor-lists.json", {"schema": "opennv-semantic-actor-lists/v1", "lists": actor_lists})
    write("actor-packages.json", {"schema": "opennv-semantic-actor-packages/v1", "packages": actor_packages})
    write("actor-placements.json", {"schema": "opennv-semantic-actor-placements/v1", "placements": actor_placements})
    navmesh_buckets: dict[int, list[dict]] = defaultdict(list)
    for row in navmeshes:
        cell = str((row.get("navmeshData") or {}).get("cell") or row.get("parentCell") or "0x0")
        navmesh_buckets[int(cell, 16) & 0xFF].append(row)
    for bucket in sorted(navmesh_buckets):
        write(f"navmeshes/{bucket:02x}.json", {
            "schema": "opennv-semantic-navmesh-shard/v1",
            "bucket": bucket,
            "navmeshes": navmesh_buckets[bucket],
        })
    write("placement-bases.json", {"schema": "opennv-semantic-placement-bases/v1", "records": placement_bases})

    placement_buckets: dict[int, list[dict]] = defaultdict(list)
    for form_id, row in live_placements.items():
        placement_buckets[form_id & 0xFF].append(row)
    for bucket in sorted(placement_buckets):
        write(f"placements/{bucket:02x}.json", {
            "schema": "opennv-semantic-placement-shard/v1",
            "bucket": bucket,
            "placements": sorted(placement_buckets[bucket], key=lambda row: int(row["id"], 16)),
        })

    manifest = {
        "schema": "opennv-semantic-database/v1",
        "bootstrap_sha256": hashlib.sha256(bootstrap_path.read_bytes()).hexdigest(),
        "resolved_manifest_sha256": hashlib.sha256(resolved_manifest_path.read_bytes()).hexdigest(),
        "load_order_sha256": resolved_manifest["load_order_sha256"],
        "counts": {
            "winning_records": len(winning_records),
            "live_records": len(live_records),
            "worlds": len(live_worlds),
            "cells": len(live_cells),
            "placements": len(live_placements),
            "actor_bases": len(actor_bases),
            "actor_lists": len(actor_lists),
            "actor_packages": len(actor_packages),
            "actor_placements": len(actor_placements),
            "navmeshes": len(navmeshes),
            "navmesh_vertices": navmesh_vertices,
            "navmesh_triangles": navmesh_triangles,
            "invalid_navmesh_door_triangles": invalid_navmesh_door_triangles,
            "unresolved_navmesh_external_links": unresolved_navmesh_external_links,
            "invalid_navmesh_external_triangles": invalid_navmesh_external_triangles,
            "placement_bases": len(placement_bases),
            "spatially_reassigned_placements": spatially_reassigned,
            "unresolved_exterior_spatial_cells": unresolved_exterior_spatial_cells,
            "resolved_land_texture_layers": resolved_land_textures,
            "unresolved_land_texture_layers": unresolved_land_textures,
        },
        "artifacts": artifacts,
    }
    (output_dir / "manifest.json").write_bytes(json.dumps(manifest, indent=2).encode() + b"\n")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--resolved-manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    result = compile_semantics(
        bootstrap_path=args.bootstrap.resolve(), data_root=args.data_root.resolve(),
        resolved_manifest_path=args.resolved_manifest.resolve(), output_dir=args.output_dir.resolve())
    print("OPENNV_SEMANTIC_DATABASE " + json.dumps(result["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
