#!/usr/bin/env python3
"""Audit every winning Fallout: New Vegas held-weapon asset in an OpenMW profile.

The report is derived from the configured plugin and fallback-archive order.  It
does not glob a convenient mesh directory or substitute MOD4 world models for
held MODL/MWD variants.  Each resolved NIF is hashed and inspected for the
native attachment/ray/ejection landmarks consumed by OpenNV VR.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
import shutil
import struct
import subprocess
import sys
import time
import zlib
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Mapping, Sequence

if not hasattr(time, "clock"):
    time.clock = time.perf_counter  # type: ignore[attr-defined]

from pyffi.formats.nif import NifFormat  # noqa: E402

import export_fnv_parity_corpus as corpus  # noqa: E402


SCHEMA = "nikami-fnv-weapon-attachment-corpus/v1"
DELETED = 0x20
COMPRESSED = 0x00040000
FAMILY_PREFIX = {
    0: "h2h",
    1: "1hm",
    2: "2hm",
    3: "1hp",
    4: "1hp",
    5: "2hr",
    6: "2ha",
    7: "2hr",
    8: "2hh",
    9: "2hl",
    10: "1gt",
    11: "1md",
    12: "1lm",
    13: "1gt",
}


def u32(data, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def zstr(value) -> str:
    return bytes(value).split(b"\0", 1)[0].decode("cp1252", errors="replace")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_mesh_path(value: str) -> str:
    value = value.replace("/", "\\").strip("\\")
    if not value.casefold().startswith("meshes\\"):
        value = "meshes\\" + value
    return value.casefold()


def family_class(animation_type: int | None) -> str:
    if animation_type is None:
        return "invalid"
    if animation_type <= 2:
        return "melee"
    if animation_type <= 9:
        return "ranged"
    if animation_type <= 13:
        return "thrown-or-placed"
    return "invalid"


@dataclass(slots=True)
class WeaponRecord:
    form_id: int
    source_index: int
    source_name: str
    flags: int
    editor_id: str = ""
    model: str = ""
    shell_casing_model: str = ""
    world_model: str = ""
    mod_models: list[str] = field(default_factory=lambda: [""] * 7)
    animation_type: int | None = None
    hand_grip: int | None = None
    projectile_form_id: int | None = None
    num_projectiles: int = 0

    @property
    def deleted(self) -> bool:
        return bool(self.flags & DELETED)


def parse_weapon_payload(
    data,
    start: int,
    end: int,
    source: corpus.PluginSource,
    master_indices: Sequence[int],
    raw_form_id: int,
    flags: int,
) -> WeaponRecord:
    form_id = corpus._resolve_form_id(raw_form_id, source, master_indices, "WEAP header")
    if form_id is None:
        raise corpus.CorpusError(f"Zero WEAP FormID in {source.name}")
    record = WeaponRecord(form_id, source.load_index, source.name, flags)
    context = f"{source.name}:WEAP:0x{raw_form_id:08x}"
    for name, offset, size in corpus._subrecords(data, start, end, context):
        value = data[offset : offset + size]
        if name == b"EDID":
            record.editor_id = zstr(value)
        elif name == b"MODL":
            record.model = zstr(value)
        elif name == b"MOD2":
            record.shell_casing_model = zstr(value)
        elif name == b"MOD4":
            record.world_model = zstr(value)
        elif len(name) == 4 and name[:3] == b"MWD" and 49 <= name[3] <= 55:
            record.mod_models[name[3] - 49] = zstr(value)
        elif name == b"DNAM" and size >= 1:
            record.animation_type = int(value[0])
            if size >= 14:
                record.hand_grip = int(value[13])
            if size >= 43:
                record.projectile_form_id = corpus._resolve_form_id(
                    u32(value, 36), source, master_indices, f"{context}:DNAM.projectile"
                )
                record.num_projectiles = int(value[42])
    return record


def iter_weapon_records(
    source: corpus.PluginSource, by_name: Mapping[str, corpus.PluginSource]
) -> Iterator[WeaponRecord]:
    master_indices = corpus._master_indices(source, by_name)
    with source.path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        first_end = source.header_size + u32(data, 4)

        def walk(start: int, end: int) -> Iterator[WeaponRecord]:
            offset = start
            while offset < end:
                if offset + source.header_size > end:
                    raise corpus.CorpusError(f"Truncated record header in {source.name} at 0x{offset:x}")
                signature = bytes(data[offset : offset + 4])
                if signature == b"GRUP":
                    group_size = u32(data, offset + 4)
                    group_end = offset + group_size
                    if group_size < source.header_size or group_end > end:
                        raise corpus.CorpusError(f"Malformed GRUP in {source.name} at 0x{offset:x}")
                    yield from walk(offset + source.header_size, group_end)
                    offset = group_end
                    continue
                payload_size = u32(data, offset + 4)
                flags = u32(data, offset + 8)
                raw_form_id = u32(data, offset + 12)
                payload_start = offset + source.header_size
                payload_end = payload_start + payload_size
                if payload_end > end:
                    raise corpus.CorpusError(
                        f"{signature!r} record overruns {source.name} at 0x{offset:x}"
                    )
                if signature == b"WEAP":
                    if flags & COMPRESSED:
                        if payload_size < 4:
                            raise corpus.CorpusError(f"Compressed WEAP too short in {source.name}")
                        expected_size = u32(data, payload_start)
                        unpacked = zlib.decompress(data[payload_start + 4 : payload_end])
                        if len(unpacked) != expected_size:
                            raise corpus.CorpusError(
                                f"WEAP decompressed size mismatch in {source.name}: "
                                f"{len(unpacked)} != {expected_size}"
                            )
                        yield parse_weapon_payload(
                            unpacked, 0, len(unpacked), source, master_indices, raw_form_id, flags
                        )
                    else:
                        yield parse_weapon_payload(
                            data, payload_start, payload_end, source, master_indices, raw_form_id, flags
                        )
                offset = payload_end

        yield from walk(first_end, len(data))


def run_bsatool(bsatool: Path, arguments: Sequence[str]) -> str:
    result = subprocess.run(
        [str(bsatool), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise corpus.CorpusError(
            f"bsatool {' '.join(arguments)} failed ({result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    if result.stderr.strip():
        raise corpus.CorpusError(f"bsatool emitted stderr: {result.stderr.strip()}")
    return result.stdout


@dataclass(frozen=True, slots=True)
class ResourceSource:
    kind: str
    name: str
    path: Path
    archive_entry: str = ""


class ResourceResolver:
    def __init__(self, config: Path, bsatool: Path, cache_root: Path):
        self.sources = corpus.read_openmw_config_sources(config)
        self.bsatool = bsatool.resolve()
        self.cache_root = cache_root.resolve()
        self.archives = corpus.archive_sources_from_config(config)
        self.archive_winners: dict[str, tuple[corpus.ArchiveSource, str]] = {}
        for archive in self.archives:
            for line in run_bsatool(self.bsatool, ("list", str(archive.path))).splitlines():
                exact = line.rstrip("\r")
                if exact:
                    self.archive_winners[corpus.normalize_vfs_path(exact)] = (archive, exact)

    def source(self, resource: str) -> ResourceSource | None:
        normalized = normalized_mesh_path(resource)
        relative = Path(normalized.replace("\\", os.sep))
        for data_root in reversed(self.sources.data_roots):
            candidate = data_root / relative
            if candidate.is_file():
                return ResourceSource("loose", data_root.name, candidate.resolve())
        archive_entry = self.archive_winners.get(corpus.normalize_vfs_path(normalized))
        if archive_entry is None:
            return None
        archive, exact = archive_entry
        digest = hashlib.sha1(str(archive.path.resolve()).casefold().encode("utf-8")).hexdigest()[:12]
        extract_root = self.cache_root / digest
        target = extract_root / Path(exact.replace("\\", os.sep))
        if not target.is_file():
            extract_root.mkdir(parents=True, exist_ok=True)
            run_bsatool(self.bsatool, ("extract", "-f", str(archive.path), exact, str(extract_root)))
        if not target.is_file():
            # Some bsatool/Windows combinations normalize archive member case.
            normalized_target = extract_root / Path(normalized.replace("\\", os.sep))
            if normalized_target.is_file():
                target = normalized_target
            else:
                raise corpus.CorpusError(f"Extraction did not produce {exact} from {archive.path}")
        return ResourceSource("archive", archive.name, target.resolve(), exact)


def block_name(block) -> str:
    value = getattr(block, "name", b"")
    if not value:
        return ""
    return bytes(value).decode("utf-8", errors="replace")


def canonical_node_name(value: str) -> str:
    return "".join(character.casefold() for character in value if character.isalnum())


def vector3(value) -> list[float]:
    return [float(value.x), float(value.y), float(value.z)]


def matrix3(value) -> list[list[float]]:
    return [
        [float(value.m_11), float(value.m_12), float(value.m_13)],
        [float(value.m_21), float(value.m_22), float(value.m_23)],
        [float(value.m_31), float(value.m_32), float(value.m_33)],
    ]


def inspect_nif(path: Path) -> dict:
    data = NifFormat.Data()
    with path.open("rb") as stream:
        data.read(stream)
    if not data.roots:
        raise corpus.CorpusError(f"NIF has no root: {path}")
    root = data.roots[0]
    names: dict[str, list[dict]] = defaultdict(list)
    skin_types: Counter[str] = Counter()
    geometry_count = 0
    vertex_count = 0
    for block in data.blocks:
        name = block_name(block)
        if name:
            entry: dict = {"name": name, "type": type(block).__name__}
            if hasattr(block, "get_transform"):
                try:
                    transform = block.get_transform(root)
                    entry["modelTranslation"] = vector3(transform.get_translation())
                    entry["modelRotation"] = matrix3(transform.get_matrix_33())
                except (TypeError, ValueError, AttributeError):
                    pass
            names[name.casefold()].append(entry)
        type_name = type(block).__name__
        if "SkinInstance" in type_name:
            skin_types[type_name] += 1
        geometry_data = getattr(block, "data", None)
        vertices = getattr(geometry_data, "vertices", None)
        if vertices is not None and len(vertices) > 0:
            geometry_count += 1
            vertex_count += len(vertices)

    role_terms = ("projectile", "shellcasing", "trigger", "sight", "handle", "stock", "blade", "grip")
    role_nodes = [
        entry
        for key in sorted(names)
        if any(term in key for term in role_terms)
        for entry in names[key]
    ]
    projectile_candidates = [
        entry
        for entries in names.values()
        for entry in entries
        if canonical_node_name(entry["name"]) == "projectilenode"
    ]
    exact_projectile_candidates = [
        entry for entry in projectile_candidates if entry["name"].casefold() == "projectilenode"
    ]
    if exact_projectile_candidates:
        projectile_match_kind = "exact"
        best_projectile_candidates = exact_projectile_candidates
    else:
        projectile_match_kind = "canonical" if projectile_candidates else "none"
        best_projectile_candidates = projectile_candidates
    return {
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
        "rootName": block_name(root),
        "rootType": type(root).__name__,
        "geometryCount": geometry_count,
        "vertexCount": vertex_count,
        "skinInstances": dict(sorted(skin_types.items())),
        "hasSkin": bool(skin_types),
        "projectileNodes": names.get("projectilenode", []),
        "projectileNodeCandidates": projectile_candidates,
        "projectileNodeBestCandidates": best_projectile_candidates,
        "projectileNodeMatchKind": projectile_match_kind,
        "shellCasingNodes": names.get("shellcasingnode", []),
        "boneOffsetNodes": names.get("boneoffset", []),
        "roleNodes": role_nodes,
    }


def build_report(config: Path, bsatool: Path, cache_root: Path) -> dict:
    plugin_paths = corpus.plugin_paths_from_config(config)
    sources = corpus.inspect_plugins(plugin_paths)
    by_name = {source.name.casefold(): source for source in sources}
    winners: dict[int, WeaponRecord] = {}
    physical = 0
    for source in sources:
        for record in iter_weapon_records(source, by_name):
            physical += 1
            winners[record.form_id] = record
    live = [record for record in winners.values() if not record.deleted]

    resolver = ResourceResolver(config, bsatool, cache_root)
    first_person_hand_grips: dict[tuple[str, int], list[str]] = defaultdict(list)
    for normalized in resolver.archive_winners:
        folded = normalized.replace("/", "\\").casefold()
        if "\\characters\\_1stperson\\" not in folded or "handgrip" not in folded or not folded.endswith(".kf"):
            continue
        filename = folded.rsplit("\\", 1)[-1]
        for family in sorted(set(FAMILY_PREFIX.values())):
            prefix = family + "handgrip"
            if not filename.startswith(prefix):
                continue
            suffix = filename[len(prefix):]
            digits = ""
            for character in suffix:
                if not character.isdigit():
                    break
                digits += character
            if digits:
                first_person_hand_grips[(family, int(digits))].append(folded)
            break
    for candidates in first_person_hand_grips.values():
        candidates.sort()
    references: dict[str, list[dict]] = defaultdict(list)
    for record in live:
        if record.model:
            references[normalized_mesh_path(record.model)].append(
                {"formId": f"0x{record.form_id:08x}", "editorId": record.editor_id, "slot": "MODL",
                 "animationType": record.animation_type}
            )
        for index, model in enumerate(record.mod_models, 1):
            if model:
                references[normalized_mesh_path(model)].append(
                    {"formId": f"0x{record.form_id:08x}", "editorId": record.editor_id,
                     "slot": f"MWD{index}", "animationType": record.animation_type}
                )

    assets: list[dict] = []
    asset_by_path: dict[str, dict] = {}
    for model in sorted(references):
        source = resolver.source(model)
        if source is None:
            asset = {
                "model": model,
                "status": "missing",
                "references": references[model],
            }
        else:
            nif = inspect_nif(source.path)
            asset = {
                "model": model,
                "status": "resolved",
                "sourceKind": source.kind,
                "sourceName": source.name,
                "archiveEntry": source.archive_entry,
                "attachmentClass": "skinned-master" if nif["hasSkin"] else "rigid-native-Weapon",
                "references": references[model],
                **nif,
            }
        asset_by_path[model] = asset
        assets.append(asset)

    record_rows: list[dict] = []
    for record in sorted(live, key=lambda item: item.form_id):
        model_key = normalized_mesh_path(record.model) if record.model else ""
        model_asset = asset_by_path.get(model_key)
        family = FAMILY_PREFIX.get(record.animation_type) if record.animation_type is not None else None
        hand_grip_index: int | None
        if record.hand_grip == 0xff:
            hand_grip_index = 0
        elif record.hand_grip is not None and 0xe6 <= record.hand_grip <= 0xeb:
            hand_grip_index = record.hand_grip - 0xe6 + 1
        else:
            hand_grip_index = None
        hand_grip_candidates = (
            first_person_hand_grips.get((family, hand_grip_index), [])
            if family and hand_grip_index not in (None, 0)
            else []
        )
        row = {
            "formId": f"0x{record.form_id:08x}",
            "editorId": record.editor_id,
            "winningPlugin": record.source_name,
            "animationType": record.animation_type,
            "animationFamily": family,
            "familyAim": f"meshes\\characters\\_1stperson\\{family}aim.kf" if family else "",
            "rawHandGrip": record.hand_grip,
            "handGripIndex": hand_grip_index,
            "handGripCandidates": hand_grip_candidates,
            "handGripStatus": (
                "family-aim-only"
                if hand_grip_index == 0
                else "authored-overlay"
                if len(hand_grip_candidates) == 1
                else "ambiguous-overlay"
                if len(hand_grip_candidates) > 1
                else "missing-overlay"
                if hand_grip_index is not None
                else "invalid-selector"
            ),
            "familyClass": family_class(record.animation_type),
            "model": model_key,
            "worldModelMOD4": normalized_mesh_path(record.world_model) if record.world_model else "",
            "shellCasingMOD2": normalized_mesh_path(record.shell_casing_model)
                if record.shell_casing_model else "",
            "modModels": [normalized_mesh_path(value) if value else "" for value in record.mod_models],
            "modelStatus": model_asset["status"] if model_asset else "no-held-model",
            "attachmentClass": model_asset.get("attachmentClass", "") if model_asset else "non-rendered",
            "projectileFormId": f"0x{record.projectile_form_id:08x}"
                if record.projectile_form_id is not None else "",
            "numProjectiles": record.num_projectiles,
            "projectileBacked": bool(
                model_asset and len(model_asset.get("projectileNodeBestCandidates", [])) == 1
            ),
            "projectileNodeBestCandidateCount": len(
                model_asset.get("projectileNodeBestCandidates", [])
            ) if model_asset else 0,
            "projectileNodeMatchKind": model_asset.get("projectileNodeMatchKind", "")
                if model_asset else "",
            "shellNodeBacked": bool(model_asset and model_asset.get("shellCasingNodes")),
        }
        if row["familyClass"] == "ranged" and row["modelStatus"] == "resolved":
            best_count = row["projectileNodeBestCandidateCount"]
            if not row["projectileFormId"]:
                row["productionRayStatus"] = "utility-no-projectile"
            elif best_count == 1:
                row["productionRayStatus"] = (
                    "authored-ProjectileNode"
                    if row["projectileNodeMatchKind"] == "exact"
                    else "authored-canonical-ProjectileNode"
                )
            elif best_count > 1 and best_count == row["numProjectiles"]:
                row["productionRayStatus"] = "authored-multi-ProjectileNode"
            elif best_count > 1:
                row["productionRayStatus"] = "ambiguous-ProjectileNode"
            else:
                row["productionRayStatus"] = "unsupported-no-authored-projectile-node"
        elif row["familyClass"] in ("melee", "thrown-or-placed") and row["modelStatus"] == "resolved":
            row["productionRayStatus"] = "native-family-axis"
        else:
            row["productionRayStatus"] = "not-applicable"
        record_rows.append(row)

    asset_counts = Counter(asset.get("status", "") for asset in assets)
    attachment_counts = Counter(asset.get("attachmentClass", "") for asset in assets if asset["status"] == "resolved")
    live_with_model = [row for row in record_rows if row["model"]]
    ranged_with_model = [row for row in live_with_model if row["familyClass"] == "ranged"]
    casing_records = [row for row in record_rows if row["shellCasingMOD2"]]
    unresolved_ranged = [
        row for row in ranged_with_model
        if row["productionRayStatus"].startswith(("unsupported", "ambiguous"))
    ]
    report = {
        "schema": SCHEMA,
        "generatedUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "scope": {
            "pluginOrder": [source.name for source in sources],
            "pluginSha256": {source.name: source.sha256 for source in sources},
            "archiveOrder": [source.name for source in resolver.archives],
        },
        "summary": {
            "physicalWeaponHeaders": physical,
            "winningWeaponsIncludingDeleted": len(winners),
            "winningLiveWeapons": len(live),
            "winningLiveWithHeldMODL": len(live_with_model),
            "winningLiveWithoutHeldMODL": len(live) - len(live_with_model),
            "uniqueHeldMODLAndMWDAssets": len(assets),
            "assetStatus": dict(sorted(asset_counts.items())),
            "attachmentClass": dict(sorted(attachment_counts.items())),
            "projectileBackedAssets": sum(
                len(asset.get("projectileNodeBestCandidates", [])) >= 1 for asset in assets
            ),
            "shellCasingNodeAssets": sum(bool(asset.get("shellCasingNodes")) for asset in assets),
            "winningRecordsWithShellCasingMOD2": len(casing_records),
            "rangedHeldRecords": len(ranged_with_model),
            "rangedHeldRecordsWithoutProjectileNode": len(unresolved_ranged),
            "animationTypeRecords": dict(sorted(Counter(str(record.animation_type) for record in live).items())),
            "handGripStatus": dict(sorted(Counter(row["handGripStatus"] for row in record_rows).items())),
        },
        "firstPersonHandGripAssets": [
            {"animationFamily": family, "handGripIndex": index, "candidates": candidates}
            for (family, index), candidates in sorted(first_person_hand_grips.items())
        ],
        "unsupportedRangedRecords": unresolved_ranged,
        "records": record_rows,
        "assets": assets,
        "localDiagnostics": {
            "config": str(config.resolve()),
            "bsatool": str(bsatool.resolve()),
            "cacheRoot": str(cache_root.resolve()),
        },
    }
    canonical = dict(report)
    canonical.pop("localDiagnostics")
    rendered = json.dumps(canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    report["canonicalReportSha256"] = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--bsatool", required=True, type=Path)
    parser.add_argument("--cache-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = build_report(args.config, args.bsatool, args.cache_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "pass", "output": str(args.output.resolve()), **report["summary"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
