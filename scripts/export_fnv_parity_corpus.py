#!/usr/bin/env python3
"""Export a reproducible Fallout: New Vegas retail-corpus denominator.

This is deliberately a static reader.  It never starts Fallout or OpenMW and
never extracts archive contents.  Plugin counts use TES4-family record headers
after master-aware FormID resolution and load-order override/deletion handling.
Archive counts use OpenMW's ``bsatool list`` command against the configured
fallback archives.

``--strict-official-profile --verify-denominators`` is the fail-closed Layer-0
gate.  Its canonical report is path-independent; machine-local paths live only
under ``localDiagnostics`` and are excluded from ``canonicalReportSha256``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import subprocess
import struct
import sys
import unicodedata
import zlib
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence


OFFICIAL_NAMES = (
    "FalloutNV.esm",
    "DeadMoney.esm",
    "HonestHearts.esm",
    "OldWorldBlues.esm",
    "LonesomeRoad.esm",
    "GunRunnersArsenal.esm",
    "CaravanPack.esm",
    "ClassicPack.esm",
    "MercenaryPack.esm",
    "TribalPack.esm",
)
OFFICIAL_ARCHIVE_NAMES = (
    "Fallout - Meshes.bsa",
    "Fallout - Misc.bsa",
    "Fallout - Sound.bsa",
    "Fallout - Textures.bsa",
    "Fallout - Textures2.bsa",
    "Fallout - Voices1.bsa",
    "DeadMoney - Main.bsa",
    "DeadMoney - Sounds.bsa",
    "HonestHearts - Main.bsa",
    "HonestHearts - Sounds.bsa",
    "OldWorldBlues - Main.bsa",
    "OldWorldBlues - Sounds.bsa",
    "LonesomeRoad - Main.bsa",
    "LonesomeRoad - Sounds.bsa",
    "GunRunnersArsenal - Main.bsa",
    "GunRunnersArsenal - Sounds.bsa",
    "CaravanPack - Main.bsa",
    "ClassicPack - Main.bsa",
    "MercenaryPack - Main.bsa",
    "TribalPack - Main.bsa",
    "Update.bsa",
)
HELPER_NAME = "FNVR.esp"
SCOPE_ID = "fnv-ultimate-edition-en-official-v1"
DENOMINATOR_SCHEMA = "nikami-fnv-parity-denominators/v1"
REPORT_SCHEMA = "nikami-fnv-parity-corpus/v1"

# These are not permissive parser fallbacks.  They are byte-identity-locked
# exceptions for two defects in the frozen English Ultimate Edition corpus.
# A repack, another language, another record, or even the same defect at a
# different offset is an error and creates a new corpus rather than silently
# inheriting this recovery policy.
FALLOUTNV_SHA256 = "50991d36804b7d1e70df1afd7471b72f0e29d1b456ee2516a9717c002564e7c1"
GRA_SHA256 = "aee27930699494f0626d24a3a8ae947fe447e33edc0ed46762e54faab4c05a1e"
ALLOWED_UNRESOLVABLE_FORM_IDS = frozenset(
    {
        (GRA_SHA256, 0x00032168, "REFR", 0x02000801),
        (GRA_SHA256, 0x00032168, "REFR.NAME", 0x02000800),
    }
)
ALLOWED_ZLIB_CHECKSUM_RECOVERIES = frozenset(
    {(FALLOUTNV_SHA256, 0x0B0CFF04, "LAND", 0x00150FC0)}
)
EXPECTED_BSATOOL_BYTES_BY_SHA256 = {
    "8c6d081baa377daf0f6c19f81e7fd6ec2a5e25eb7d2698251ecda9a984868f08": 404_992,
}

REC_DELETED = 0x00000020
REC_COMPRESSED = 0x00040000
PLACED_TYPES = ("REFR", "ACHR", "ACRE", "PGRE", "PHZD")
ACTOR_BASE_TYPES = ("NPC_", "CREA")
ACTIVATOR_BASE_TYPES = ("ACTI", "TACT")
WORLD_SYSTEM_TYPES = ("WRLD", "CLMT", "WTHR", "REGN", "ECZN", "PACK")

# Only these subrecords affect the compact feature denominator.  SCRI is
# intentionally counted on every record type rather than on a hand-maintained
# list of scriptable objects.
COUNTED_SUBRECORDS = frozenset(
    {
        b"CTDA",
        b"CTDT",
        b"INDX",
        b"INAM",
        b"ITXT",
        b"NAM1",
        b"QOBJ",
        b"QSDT",
        b"QSTA",
        b"RNAM",
        b"SCDA",
        b"SCRI",
        b"SCRO",
        b"SCTX",
        b"TCLT",
        b"TRDT",
        b"XMRK",
        b"XRDO",
        b"XTEL",
        b"CNTO",
    }
)

CRAFTING_EDID_TOKENS = (
    "workbench",
    "reloadingbench",
    "campfirecrafting",
    "nvdlc02campfire",
    "craftingoven",
    "hotplate",
)


class CorpusError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class OpenMWConfigSources:
    path: Path
    data_roots: tuple[Path, ...]
    data_entries: tuple[tuple[str, Path], ...]
    content: tuple[str, ...]
    fallback_archives: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ArchiveSource:
    name: str
    path: Path


def _u16(data, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _zstr(data) -> str:
    return bytes(data).split(b"\0", 1)[0].decode("cp1252", errors="replace")


def _strip_config_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _config_path(value: str, config_dir: Path) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = config_dir / path
    return path.resolve()


def read_openmw_config_sources(config_path: Path) -> OpenMWConfigSources:
    """Read only the OpenMW source-order fields needed by this census."""

    config_path = config_path.resolve()
    if not config_path.is_file():
        raise CorpusError(f"OpenMW config does not exist: {config_path}")

    data_roots: list[Path] = []
    data_entries: list[tuple[str, Path]] = []
    content: list[str] = []
    fallback_archives: list[str] = []
    for raw_line in config_path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip().lower()
        value = _strip_config_value(value)
        if key in ("data", "data-local"):
            resolved = _config_path(value, config_path.parent)
            data_roots.append(resolved)
            data_entries.append((key, resolved))
        elif key == "content":
            content.append(value)
        elif key == "fallback-archive":
            fallback_archives.append(value)

    if not content:
        raise CorpusError(f"No content entries in OpenMW config: {config_path}")
    if not data_roots:
        raise CorpusError(f"No data/data-local entries in OpenMW config: {config_path}")

    return OpenMWConfigSources(
        path=config_path,
        data_roots=tuple(data_roots),
        data_entries=tuple(data_entries),
        content=tuple(content),
        fallback_archives=tuple(fallback_archives),
    )


def _resolve_config_entries(
    entries: Sequence[str], data_roots: Sequence[Path], config_key: str
) -> list[Path]:
    """Resolve entries with the last configured data root taking precedence."""

    resolved: list[Path] = []
    for entry in entries:
        direct = Path(entry).expanduser()
        candidates = [direct] if direct.is_absolute() else [root / entry for root in reversed(data_roots)]
        found = next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)
        if found is None:
            searched = ", ".join(str(candidate) for candidate in candidates)
            raise CorpusError(f"Could not resolve {config_key}={entry}; searched: {searched}")
        resolved.append(found)
    return resolved


def plugin_paths_from_config(config_path: Path) -> list[Path]:
    """Resolve OpenMW content entries against the configured data roots."""

    sources = read_openmw_config_sources(config_path)
    return _resolve_config_entries(sources.content, sources.data_roots, "content")


def archive_sources_from_config(config_path: Path) -> list[ArchiveSource]:
    """Resolve fallback archives in authored order using OpenMW data precedence."""

    sources = read_openmw_config_sources(config_path)
    if not sources.fallback_archives:
        raise CorpusError(f"No fallback-archive entries in OpenMW config: {sources.path}")
    paths = _resolve_config_entries(
        sources.fallback_archives, sources.data_roots, "fallback-archive"
    )
    return [
        ArchiveSource(name=name, path=path)
        for name, path in zip(sources.fallback_archives, paths, strict=True)
    ]


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _decode_tool_output(data: bytes) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp1252", errors="replace")


def _run_bsatool(
    bsatool_path: Path,
    arguments: Sequence[str],
    accepted_return_codes: Sequence[int] = (0,),
) -> str:
    try:
        result = subprocess.run(
            [str(bsatool_path), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise CorpusError(f"Could not run bsatool: {error}") from error
    stdout = _decode_tool_output(result.stdout)
    stderr = _decode_tool_output(result.stderr)
    if result.returncode not in accepted_return_codes:
        detail = stderr.strip() or stdout.strip() or "no diagnostic output"
        raise CorpusError(
            f"bsatool {' '.join(arguments)} failed with exit code {result.returncode}: {detail}"
        )
    if stderr.strip():
        raise CorpusError(
            f"bsatool {' '.join(arguments)} emitted unexpected stderr: {stderr.strip()}"
        )
    return stdout


def normalize_vfs_path(path: str) -> str:
    """Normalize an archive member path for OpenMW-style VFS comparison."""

    slash_path = unicodedata.normalize("NFC", path).replace("\\", "/")
    parts = [part for part in slash_path.split("/") if part not in ("", ".")]
    if not parts or any(part == ".." for part in parts):
        raise CorpusError(f"Invalid archive member path: {path!r}")
    return "/".join(parts).casefold()


def _path_extension(normalized_path: str) -> str:
    filename = normalized_path.rsplit("/", 1)[-1]
    if "." not in filename or filename.endswith("."):
        return "<none>"
    return filename.rsplit(".", 1)[1]


def aggregate_archive_entries(
    listings: Sequence[tuple[ArchiveSource, Sequence[str]]],
) -> dict:
    """Apply last-archive-wins VFS semantics to already listed archive paths."""

    authored_extensions: Counter[str] = Counter()
    normalized_by_archive: list[list[str]] = []
    winners: dict[str, int] = {}

    for archive_index, (_, entries) in enumerate(listings):
        normalized_entries: list[str] = []
        for entry in entries:
            normalized = normalize_vfs_path(entry)
            normalized_entries.append(normalized)
            authored_extensions[_path_extension(normalized)] += 1
            winners[normalized] = archive_index
        normalized_by_archive.append(normalized_entries)

    winning_extensions = Counter(_path_extension(path) for path in winners)
    winning_by_archive = Counter(winners.values())
    per_archive: list[dict] = []
    for archive_index, normalized_entries in enumerate(normalized_by_archive):
        authored = len(normalized_entries)
        winning = winning_by_archive[archive_index]
        listing_digest = hashlib.sha256()
        for normalized in normalized_entries:
            listing_digest.update(normalized.encode("utf-8"))
            listing_digest.update(b"\n")
        per_archive.append(
            {
                "authoredEntries": authored,
                "winningVfsPaths": winning,
                "overriddenEntries": authored - winning,
                "normalizedListingSha256": listing_digest.hexdigest(),
            }
        )

    authored_total = sum(len(entries) for entries in normalized_by_archive)
    return {
        "authoredEntries": authored_total,
        "uniqueNormalizedVfsPaths": len(winners),
        "duplicateOrOverriddenEntries": authored_total - len(winners),
        "extensionCounts": {
            "authored": dict(sorted(authored_extensions.items())),
            "winning": dict(sorted(winning_extensions.items())),
        },
        "perArchive": per_archive,
    }


def build_archive_report(
    sources: Sequence[ArchiveSource], bsatool_path: Path, repo_root: Path | None = None
) -> dict:
    """List and summarize only the frozen official fallback-archive layer."""

    bsatool_path = bsatool_path.resolve()
    if not bsatool_path.is_file():
        raise CorpusError(f"bsatool does not exist: {bsatool_path}")

    official_keys = {name.casefold() for name in OFFICIAL_ARCHIVE_NAMES}
    selected = [source for source in sources if source.name.casefold() in official_keys]
    actual_names = [source.name for source in selected]
    actual_keys = [name.casefold() for name in actual_names]
    expected_keys = [name.casefold() for name in OFFICIAL_ARCHIVE_NAMES]
    missing = [name for name in OFFICIAL_ARCHIVE_NAMES if name.casefold() not in actual_keys]
    extras = [source.name for source in sources if source.name.casefold() not in official_keys]
    duplicate_names = sorted(
        name for name, count in Counter(actual_keys).items() if count > 1
    )
    warnings: list[str] = []
    if missing:
        warnings.append("Missing official archives: " + ", ".join(missing))
    if actual_keys != expected_keys:
        warnings.append("Official archives are not in the frozen Fallout: New Vegas order")
    if duplicate_names:
        warnings.append("Duplicate official archive entries: " + ", ".join(duplicate_names))
    if extras:
        warnings.append("Ignored non-official fallback archives: " + ", ".join(extras))

    listings: list[tuple[ArchiveSource, list[str]]] = []
    for source in selected:
        output = _run_bsatool(bsatool_path, ("list", str(source.path)))
        entries = [line.rstrip("\r") for line in output.splitlines() if line.rstrip("\r")]
        listings.append((source, entries))
    aggregate = aggregate_archive_entries(listings)

    archive_metadata: list[dict] = []
    for order, ((source, _), counts) in enumerate(
        zip(listings, aggregate.pop("perArchive"), strict=True)
    ):
        archive_metadata.append(
            {
                "order": order,
                "name": source.name,
                "logicalId": f"official-archive:{source.name}",
                "bytes": source.path.stat().st_size,
                "sha256": _sha256_file(source.path),
                **counts,
            }
        )

    # OpenMW 0.49's BSATool 1.1 reports its version correctly but exits 1.
    # Accept that documented version-query behavior only; listings remain
    # strict exit-zero operations.
    version_output = _run_bsatool(
        bsatool_path, ("--version",), accepted_return_codes=(0, 1)
    ).strip()
    repo_local = False
    if repo_root is not None:
        try:
            bsatool_path.relative_to(repo_root.resolve())
            repo_local = True
        except ValueError:
            pass

    return {
        "semantics": {
            "authoredEntries": "Every non-empty path emitted by bsatool list for each selected archive.",
            "normalizedVfsPath": "NFC Unicode, slash separators, empty and dot segments removed, then Unicode case-folded.",
            "winning": "One path after the last occurrence in frozen fallback-archive order wins.",
            "scope": "Official BSA directory listings only; assets are never extracted or interpreted.",
        },
        "source": {
            "expectedOfficialArchiveCount": len(OFFICIAL_ARCHIVE_NAMES),
            "completeOfficialSet": actual_keys == expected_keys,
            "warnings": warnings,
        },
        "tool": {
            "name": "OpenMW bsatool",
            "logicalId": "openmw-bsatool",
            "bytes": bsatool_path.stat().st_size,
            "sha256": _sha256_file(bsatool_path),
            "versionOutput": version_output,
            "listingInvocation": ["bsatool", "list", "<archive-path>"],
        },
        **aggregate,
        "archives": archive_metadata,
        "localDiagnostics": {
            "canonical": False,
            "excludedFromCanonicalSha256": True,
            "bsatoolPath": str(bsatool_path),
            "bsatoolRepoLocal": repo_local,
            "archivePaths": [str(source.path.resolve()) for source in selected],
        },
    }


def _detect_header_size(data, path: Path) -> int:
    if len(data) < 24 or data[:4] != b"TES4":
        raise CorpusError(f"Not a TES4-family plugin: {path}")
    likely_subrecords = (b"HEDR", b"OFST", b"CNAM", b"SNAM", b"MAST", b"DATA")
    if data[20:24] in likely_subrecords:
        return 20
    if data[24:28] in likely_subrecords:
        return 24
    size = _u32(data, 4)
    if 20 + size + 4 <= len(data) and data[20 + size : 20 + size + 4] == b"GRUP":
        return 20
    return 24


def _subrecords(data, start: int, end: int, context: str) -> Iterator[tuple[bytes, int, int]]:
    offset = start
    extended_size: int | None = None
    while offset < end:
        if offset + 6 > end:
            raise CorpusError(f"Truncated subrecord header in {context} at 0x{offset:x}")
        name = bytes(data[offset : offset + 4])
        size = _u16(data, offset + 4)
        offset += 6
        if name == b"XXXX":
            if size < 4 or offset + size > end:
                raise CorpusError(f"Malformed XXXX subrecord in {context} at 0x{offset - 6:x}")
            extended_size = _u32(data, offset)
            offset += size
            continue
        actual_size = extended_size if extended_size is not None else size
        extended_size = None
        if offset + actual_size > end:
            raise CorpusError(
                f"Subrecord {name!r} overruns {context}: 0x{offset:x}+{actual_size} > 0x{end:x}"
            )
        yield name, offset, actual_size
        offset += actual_size
    if extended_size is not None:
        raise CorpusError(f"Dangling XXXX subrecord in {context}")


@dataclass(frozen=True, slots=True)
class PluginSource:
    path: Path
    name: str
    load_index: int
    role: str
    header_size: int
    masters: tuple[str, ...]
    localized: bool
    size: int
    sha256: str


@dataclass(frozen=True, slots=True)
class RecordFacts:
    form_id: int | None
    rtype: str
    flags: int
    source_index: int
    base: int | None = None
    metrics: tuple[tuple[str, int], ...] = ()
    editor_id: str = ""
    full_name: str = ""
    cell_flags: int | None = None
    water_types: tuple[int, ...] = ()

    @property
    def deleted(self) -> bool:
        return bool(self.flags & REC_DELETED)

    def count(self, name: str) -> int:
        for metric_name, value in self.metrics:
            if metric_name == name:
                return value
        return 0


def _role_for_name(name: str) -> str:
    lowered = name.casefold()
    if lowered in {item.casefold() for item in OFFICIAL_NAMES}:
        return "official"
    if lowered == HELPER_NAME.casefold():
        return "helper"
    return "extra"


def _read_plugin_header(path: Path, load_index: int) -> PluginSource:
    path = path.resolve()
    if not path.is_file():
        raise CorpusError(f"Plugin does not exist: {path}")
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        header_size = _detect_header_size(data, path)
        payload_size = _u32(data, 4)
        flags = _u32(data, 8)
        start = header_size
        end = start + payload_size
        if end > len(data):
            raise CorpusError(f"TES4 header overruns plugin: {path}")
        masters = tuple(
            _zstr(data[offset : offset + size])
            for name, offset, size in _subrecords(data, start, end, f"{path.name}:TES4")
            if name == b"MAST"
        )
        sha256 = hashlib.sha256(data).hexdigest()
    return PluginSource(
        path=path,
        name=path.name,
        load_index=load_index,
        role=_role_for_name(path.name),
        header_size=header_size,
        masters=masters,
        localized=bool(flags & 0x80),
        size=path.stat().st_size,
        sha256=sha256,
    )


def inspect_plugins(paths: Sequence[Path]) -> list[PluginSource]:
    if not paths:
        raise CorpusError("No plugin paths supplied")
    sources = [_read_plugin_header(Path(path), index) for index, path in enumerate(paths)]
    names: dict[str, PluginSource] = {}
    for source in sources:
        key = source.name.casefold()
        if key in names:
            raise CorpusError(f"Duplicate load-order plugin name: {source.name}")
        names[key] = source
    for source in sources:
        for master in source.masters:
            master_source = names.get(master.casefold())
            if master_source is None:
                raise CorpusError(f"{source.name} requires missing master {master}")
            if master_source.load_index >= source.load_index:
                raise CorpusError(f"{source.name} loads before its master {master}")
    return sources


def _master_indices(source: PluginSource, by_name: Mapping[str, PluginSource]) -> tuple[int, ...]:
    return tuple(by_name[name.casefold()].load_index for name in source.masters)


def _resolve_form_id(raw: int, source: PluginSource, master_indices: Sequence[int], context: str) -> int | None:
    if raw == 0:
        return None
    local_index = raw >> 24
    object_id = raw & 0x00FFFFFF
    if local_index < len(master_indices):
        owner_index = master_indices[local_index]
    elif local_index == len(master_indices):
        owner_index = source.load_index
    else:
        raise CorpusError(
            f"Invalid local FormID 0x{raw:08x} in {source.name} {context}; "
            f"plugin has {len(master_indices)} masters"
        )
    return (owner_index << 24) | object_id


def _record_facts(
    source: PluginSource,
    record_offset: int,
    rtype: str,
    raw_form: int,
    flags: int,
    payload_data,
    payload_start: int,
    payload_end: int,
    master_indices: Sequence[int],
    diagnostics: Counter[str] | None,
) -> RecordFacts:
    try:
        form_id = _resolve_form_id(raw_form, source, master_indices, f"{rtype} header")
        if form_id is None:
            raise CorpusError(f"Zero FormID on non-header {rtype} record in {source.name}")
    except CorpusError:
        allowlist_key = (source.sha256, record_offset, rtype, raw_form)
        if allowlist_key not in ALLOWED_UNRESOLVABLE_FORM_IDS:
            raise
        # One byte-identity-locked retail GRA REFR is authored with local
        # index 02 despite GRA declaring only FalloutNV.esm as index 00.  It
        # belongs in the physical-header denominator but cannot safely
        # participate in an override chain.
        form_id = None
        if diagnostics is not None:
            diagnostics[f"unresolvableRecordFormId:{rtype}"] += 1

    metrics: Counter[str] = Counter()
    base: int | None = None
    editor_id = ""
    full_name = ""
    cell_flags: int | None = None
    water_types: list[int] = []
    want_names = rtype in ("FURN", "ACTI", "TACT", "WATR")
    context = f"{source.name}:{rtype}:0x{raw_form:08x}"
    for name, offset, size in _subrecords(payload_data, payload_start, payload_end, context):
        if name in COUNTED_SUBRECORDS:
            metrics[name.decode("ascii")] += 1
        if rtype in PLACED_TYPES and name == b"NAME" and size >= 4:
            raw_base = _u32(payload_data, offset)
            try:
                base = _resolve_form_id(
                    raw_base, source, master_indices, f"{rtype}.NAME"
                )
            except CorpusError:
                allowlist_key = (
                    source.sha256,
                    record_offset,
                    f"{rtype}.NAME",
                    raw_base,
                )
                if allowlist_key not in ALLOWED_UNRESOLVABLE_FORM_IDS:
                    raise
                base = None
                if diagnostics is not None:
                    diagnostics[f"unresolvableReferencedFormId:{rtype}.NAME"] += 1
        elif want_names and name == b"EDID":
            editor_id = _zstr(payload_data[offset : offset + size])
        elif want_names and name == b"FULL" and not source.localized:
            full_name = _zstr(payload_data[offset : offset + size])
        elif rtype == "CELL" and name == b"DATA" and size >= 1:
            cell_flags = payload_data[offset]
        elif (
            (rtype == "CELL" and name == b"XCWT")
            or (rtype == "WRLD" and name in (b"NAM2", b"NAM3"))
            or (rtype == "ACTI" and name == b"WNAM")
        ) and size >= 4:
            resolved_water = _resolve_form_id(
                _u32(payload_data, offset),
                source,
                master_indices,
                f"{rtype}.{name.decode('ascii')}",
            )
            if resolved_water is not None:
                water_types.append(resolved_water)

    return RecordFacts(
        form_id=form_id,
        rtype=rtype,
        flags=flags,
        source_index=source.load_index,
        base=base,
        metrics=tuple(sorted(metrics.items())),
        editor_id=editor_id,
        full_name=full_name,
        cell_flags=cell_flags,
        water_types=tuple(water_types),
    )


def iter_plugin_records(
    source: PluginSource,
    by_name: Mapping[str, PluginSource],
    diagnostics: Counter[str] | None = None,
) -> Iterator[RecordFacts]:
    master_indices = _master_indices(source, by_name)
    with source.path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        first_size = _u32(data, 4)
        first_end = source.header_size + first_size

        def walk(start: int, end: int) -> Iterator[RecordFacts]:
            offset = start
            while offset < end:
                if offset + source.header_size > end:
                    raise CorpusError(f"Truncated record header in {source.name} at 0x{offset:x}")
                signature = bytes(data[offset : offset + 4])
                if signature == b"GRUP":
                    group_size = _u32(data, offset + 4)
                    group_end = offset + group_size
                    if group_size < source.header_size or group_end > end:
                        raise CorpusError(f"Malformed GRUP in {source.name} at 0x{offset:x}")
                    yield from walk(offset + source.header_size, group_end)
                    offset = group_end
                    continue

                try:
                    rtype = signature.decode("ascii")
                except UnicodeDecodeError as error:
                    raise CorpusError(f"Invalid record signature in {source.name} at 0x{offset:x}") from error
                payload_size = _u32(data, offset + 4)
                flags = _u32(data, offset + 8)
                raw_form = _u32(data, offset + 12)
                payload_start = offset + source.header_size
                payload_end = payload_start + payload_size
                if payload_end > end:
                    raise CorpusError(f"{rtype} record overruns {source.name} at 0x{offset:x}")

                if rtype != "TES4":
                    if flags & REC_COMPRESSED:
                        if payload_size < 4:
                            raise CorpusError(f"Compressed {rtype} is too short in {source.name} at 0x{offset:x}")
                        expected_size = _u32(data, payload_start)
                        packed = data[payload_start + 4 : payload_end]
                        try:
                            unpacked = zlib.decompress(packed)
                        except zlib.error as error:
                            recovery_key = (source.sha256, offset, rtype, raw_form)
                            if recovery_key not in ALLOWED_ZLIB_CHECKSUM_RECOVERIES:
                                raise CorpusError(
                                    f"Cannot decompress {rtype} in {source.name} at 0x{offset:x}: "
                                    f"{error}; record is not in the frozen checksum-recovery allowlist"
                                ) from error
                            # The frozen FalloutNV.esm contains one LAND whose
                            # deflate stream is complete but whose Adler-32 is
                            # wrong.  Only the exact SHA/offset/type/FormID above
                            # may use raw-deflate recovery.
                            try:
                                unpacked = zlib.decompress(packed[2:-4], -15)
                            except zlib.error as recovery_error:
                                raise CorpusError(
                                    f"Cannot decompress {rtype} in {source.name} at 0x{offset:x}: "
                                    f"{error}; raw-deflate recovery also failed: {recovery_error}"
                                ) from error
                            if diagnostics is not None:
                                diagnostics[f"recoveredZlibChecksum:{rtype}"] += 1
                        if len(unpacked) != expected_size:
                            raise CorpusError(
                                f"Decompressed size mismatch for {rtype} in {source.name} at 0x{offset:x}: "
                                f"{len(unpacked)} != {expected_size}"
                            )
                        yield _record_facts(
                            source,
                            offset,
                            rtype,
                            raw_form,
                            flags,
                            unpacked,
                            0,
                            len(unpacked),
                            master_indices,
                            diagnostics,
                        )
                    else:
                        yield _record_facts(
                            source,
                            offset,
                            rtype,
                            raw_form,
                            flags,
                            data,
                            payload_start,
                            payload_end,
                            master_indices,
                            diagnostics,
                        )
                offset = payload_end

        yield from walk(first_end, len(data))


def _is_crafting_candidate(record: RecordFacts) -> bool:
    if record.rtype != "ACTI":
        return False
    editor_id = record.editor_id.casefold()
    return any(token in editor_id for token in CRAFTING_EDID_TOKENS)


def _feature_summary(records: Iterable[RecordFacts], base_lookup: Mapping[int, RecordFacts]) -> dict:
    live = list(records)
    by_type = Counter(record.rtype for record in live)
    placements = [record for record in live if record.rtype in PLACED_TYPES]

    def base_is(record: RecordFacts, types: Sequence[str]) -> bool:
        base = base_lookup.get(record.base) if record.base is not None else None
        return base is not None and not base.deleted and base.rtype in types

    doors = [record for record in placements if base_is(record, ("DOOR",))]
    containers = [record for record in placements if base_is(record, ("CONT",))]
    actor_placements = [record for record in placements if record.rtype in ("ACHR", "ACRE")]
    terminals = [record for record in placements if base_is(record, ("TERM",))]
    activators = [record for record in placements if base_is(record, ACTIVATOR_BASE_TYPES)]
    crafting_bases = {
        record.form_id
        for record in live
        if record.form_id is not None and _is_crafting_candidate(record)
    }
    crafting_refs = [record for record in placements if record.base in crafting_bases]
    radio_bases = {
        record.form_id
        for record in live
        if record.rtype in ACTIVATOR_BASE_TYPES and (record.count("RNAM") or record.count("INAM"))
    }
    xrdo_refs = [record for record in placements if record.count("XRDO")]
    radio_refs = [record for record in placements if record.base in radio_bases or record.count("XRDO")]
    reserved_marker_refs = [record for record in placements if record.base in (0x17, 0x20)]
    infos = [record for record in live if record.rtype == "INFO"]
    quests = [record for record in live if record.rtype == "QUST"]
    terminal_records = [record for record in live if record.rtype == "TERM"]
    script_links = [record for record in live if record.count("SCRI")]
    cells = [record for record in live if record.rtype == "CELL"]
    placed_base_ids = {record.base for record in placements if record.base is not None}
    water_owners = [
        record
        for record in live
        if record.rtype in ("CELL", "WRLD")
        or (record.rtype == "ACTI" and record.form_id in placed_base_ids)
    ]
    placed_water_types = {
        water_type for record in water_owners for water_type in record.water_types
    }

    return {
        "placedRefs": {
            "total": len(placements),
            "byRecordType": {rtype: by_type.get(rtype, 0) for rtype in PLACED_TYPES},
        },
        "cells": {
            "total": len(cells),
            "interior": sum(1 for record in cells if record.cell_flags is not None and record.cell_flags & 1),
            "exterior": sum(1 for record in cells if record.cell_flags is not None and not (record.cell_flags & 1)),
            "unknownFlags": sum(1 for record in cells if record.cell_flags is None),
        },
        "doors": {
            "baseRecords": by_type.get("DOOR", 0),
            "placedRefs": len(doors),
            "teleportRefsXTEL": sum(1 for record in placements if record.count("XTEL")),
        },
        "containers": {
            "baseRecords": by_type.get("CONT", 0),
            "placedRefs": len(containers),
            "inventoryEntriesCNTO": sum(record.count("CNTO") for record in live if record.rtype == "CONT"),
        },
        "actors": {
            "baseRecords": sum(by_type.get(rtype, 0) for rtype in ACTOR_BASE_TYPES),
            "npcBases": by_type.get("NPC_", 0),
            "creatureBases": by_type.get("CREA", 0),
            "placedRefs": len(actor_placements),
            "ACHR": by_type.get("ACHR", 0),
            "ACRE": by_type.get("ACRE", 0),
        },
        "dialogue": {
            "topicsDIAL": by_type.get("DIAL", 0),
            "infosINFO": len(infos),
            "responsesTRDT": sum(record.count("TRDT") for record in infos),
            "responseTextsNAM1": sum(record.count("NAM1") for record in infos),
            "conditions": {
                "total": sum(record.count("CTDA") + record.count("CTDT") for record in infos),
                "CTDA": sum(record.count("CTDA") for record in infos),
                "CTDT": sum(record.count("CTDT") for record in infos),
            },
            "multiResponseInfos": sum(1 for record in infos if record.count("TRDT") > 1),
            "choiceEdgesTCLT": sum(record.count("TCLT") for record in infos),
        },
        "quests": {
            "recordsQUST": len(quests),
            "stagesINDX": sum(record.count("INDX") for record in quests),
            "stageEntriesQSDT": sum(record.count("QSDT") for record in quests),
            "objectivesQOBJ": sum(record.count("QOBJ") for record in quests),
            "objectiveTargetsQSTA": sum(record.count("QSTA") for record in quests),
            "conditions": sum(record.count("CTDA") + record.count("CTDT") for record in quests),
        },
        "scripts": {
            "recordsSCPT": by_type.get("SCPT", 0),
            "attachmentsSCRI": sum(record.count("SCRI") for record in live),
            "recordsWithSCRI": len(script_links),
            "compiledDataSCDA": sum(record.count("SCDA") for record in live),
            "sourceTextSCTX": sum(record.count("SCTX") for record in live),
            "referencedFormsSCRO": sum(record.count("SCRO") for record in live),
        },
        "terminals": {
            "baseRecordsTERM": len(terminal_records),
            "placedRefs": len(terminals),
            "menuItemsITXT": sum(record.count("ITXT") for record in terminal_records),
            "conditions": sum(
                record.count("CTDA") + record.count("CTDT") for record in terminal_records
            ),
        },
        "craftingCandidates": {
            "recipeRecordsRCPE": by_type.get("RCPE", 0),
            "recipeCategoriesRCCT": by_type.get("RCCT", 0),
            "candidateBaseRecords": len(crafting_bases),
            "placedCandidateRefs": len(crafting_refs),
        },
        "radios": {
            "baseRecordsWithRNAMOrINAM": len(radio_bases),
            "placedRefsWithXRDO": len(xrdo_refs),
            "placedRadioRefs": len(radio_refs),
        },
        "activators": {
            "baseRecords": sum(by_type.get(rtype, 0) for rtype in ACTIVATOR_BASE_TYPES),
            "ACTI": by_type.get("ACTI", 0),
            "TACT": by_type.get("TACT", 0),
            "placedRefs": len(activators),
        },
        "mapMarkers": {
            "placedRefsXMRK": sum(1 for record in placements if record.count("XMRK")),
        },
        "water": {
            "cellsWithXCWT": sum(1 for record in cells if record.water_types),
            "worldspacesWithNAM2OrNAM3": sum(
                1
                for record in live
                if record.rtype == "WRLD" and record.water_types
            ),
            "activatorsWithWNAM": sum(
                1
                for record in water_owners
                if record.rtype == "ACTI" and record.water_types
            ),
            "uniqueReferencedTypes": len(placed_water_types),
        },
        "engineReservedMarkers": {"placedRefs": len(reserved_marker_refs)},
        "worldSystems": {rtype: by_type.get(rtype, 0) for rtype in WORLD_SYSTEM_TYPES},
    }


def _corpus_summary(
    winners: Mapping[int, RecordFacts],
    physical_types: Counter[str],
    base_lookup: Mapping[int, RecordFacts] | None = None,
    unresolvable: int = 0,
) -> dict:
    winning_records = list(winners.values())
    live_records = [record for record in winning_records if not record.deleted]
    winning_types = Counter(record.rtype for record in winning_records)
    live_types = Counter(record.rtype for record in live_records)
    all_types = sorted(set(physical_types) | set(winning_types))
    physical = sum(physical_types.values())
    winning = len(winning_records)
    features = _feature_summary(live_records, base_lookup or winners)
    features["placedRefs"].update(
        {
            "physical": sum(physical_types.get(rtype, 0) for rtype in PLACED_TYPES),
            "winning": sum(winning_types.get(rtype, 0) for rtype in PLACED_TYPES),
            "live": sum(live_types.get(rtype, 0) for rtype in PLACED_TYPES),
        }
    )
    return {
        "records": {
            "physical": physical,
            "winning": winning,
            "live": len(live_records),
            "deletedWinners": winning - len(live_records),
            "unresolvablePhysicalRecords": unresolvable,
            "overriddenPhysicalRecords": physical - unresolvable - winning,
        },
        "recordTypes": {
            rtype: {
                "physical": physical_types.get(rtype, 0),
                "winning": winning_types.get(rtype, 0),
                "live": live_types.get(rtype, 0),
            }
            for rtype in all_types
        },
        "features": features,
    }


def build_report(paths: Sequence[Path], config_path: Path | None = None) -> dict:
    sources = inspect_plugins(paths)
    by_name = {source.name.casefold(): source for source in sources}
    official_winners: dict[int, RecordFacts] = {}
    helper_winners: dict[int, RecordFacts] = {}
    effective_winners: dict[int, RecordFacts] = {}
    official_physical: Counter[str] = Counter()
    helper_physical: Counter[str] = Counter()
    effective_physical: Counter[str] = Counter()
    official_unresolvable = 0
    helper_unresolvable = 0
    effective_unresolvable = 0
    official_physical_records_with_scri = 0
    helper_physical_records_with_scri = 0
    per_plugin: list[dict] = []
    per_plugin_types: dict[str, Counter[str]] = {}

    for source in sources:
        counts: Counter[str] = Counter()
        diagnostics: Counter[str] = Counter()
        distinct_ids: set[int] = set()
        deleted = 0
        if source.role in ("official", "helper"):
            for record in iter_plugin_records(source, by_name, diagnostics):
                counts[record.rtype] += 1
                if record.form_id is not None:
                    distinct_ids.add(record.form_id)
                deleted += int(record.deleted)
                effective_physical[record.rtype] += 1
                if record.form_id is not None:
                    effective_winners[record.form_id] = record
                else:
                    effective_unresolvable += 1
                if source.role == "official":
                    official_physical[record.rtype] += 1
                    official_physical_records_with_scri += int(bool(record.count("SCRI")))
                    if record.form_id is not None:
                        official_winners[record.form_id] = record
                    else:
                        official_unresolvable += 1
                else:
                    helper_physical[record.rtype] += 1
                    helper_physical_records_with_scri += int(bool(record.count("SCRI")))
                    if record.form_id is not None:
                        helper_winners[record.form_id] = record
                    else:
                        helper_unresolvable += 1
        per_plugin.append(
            {
                "loadIndex": source.load_index,
                "name": source.name,
                "logicalId": f"{source.role}-plugin:{source.name}",
                "role": source.role,
                "bytes": source.size,
                "sha256": source.sha256,
                "recordHeaderBytes": source.header_size,
                "localized": source.localized,
                "masters": list(source.masters),
                "physicalRecords": sum(counts.values()),
                "distinctFormIds": len(distinct_ids),
                "deletedPhysicalRecords": deleted,
                "payloadDiagnostics": dict(sorted(diagnostics.items())),
            }
        )
        per_plugin_types[source.name.casefold()] = counts

    official_actual_names = [source.name for source in sources if source.role == "official"]
    official_lookup = {name.casefold(): name for name in official_actual_names}
    missing_official = [name for name in OFFICIAL_NAMES if name.casefold() not in official_lookup]
    ordered_official = [name.casefold() for name in official_actual_names]
    expected_present_order = [name.casefold() for name in OFFICIAL_NAMES if name.casefold() in official_lookup]
    warnings: list[str] = []
    if missing_official:
        warnings.append("Missing official plugins: " + ", ".join(missing_official))
    if ordered_official != expected_present_order:
        warnings.append("Official plugins are not in canonical Fallout: New Vegas load order")
    extras = [source.name for source in sources if source.role == "extra"]
    if extras:
        warnings.append("Ignored non-corpus plugins: " + ", ".join(extras))

    helper_ids = set(helper_winners)
    helper_overrides = len(helper_ids & set(official_winners))
    helper_new = len(helper_ids - set(official_winners))
    helper_summary = _corpus_summary(
        helper_winners, helper_physical, effective_winners, helper_unresolvable
    )
    helper_summary["layerRelationship"] = {
        "overridesOfficial": helper_overrides,
        "newRecords": helper_new,
    }

    fallout_source = next((source for source in sources if source.name.casefold() == "falloutnv.esm"), None)
    fallout_plugin = next(
        (plugin for plugin in per_plugin if plugin["name"].casefold() == "falloutnv.esm"), None
    )
    regression = None
    if fallout_source is not None and fallout_plugin is not None:
        expected_records = 465_016
        expected_placements = 314_269
        actual_placements = sum(
            count
            for rtype, count in per_plugin_types[fallout_source.name.casefold()].items()
            if rtype in PLACED_TYPES
        )
        actual_records = fallout_plugin["physicalRecords"]
        regression = {
            "priorCatalogExpected": {
                "records": expected_records,
                "placements": expected_placements,
            },
            "actual": {"records": actual_records, "placements": actual_placements},
            "status": (
                "pass"
                if actual_records == expected_records and actual_placements == expected_placements
                else "fail"
            ),
        }

    return {
        "schema": REPORT_SCHEMA,
        "scopeId": SCOPE_ID,
        "semantics": {
            "physical": "Every non-TES4 record instance in the selected plugin layer.",
            "winning": "One last-loaded record per master-resolved 32-bit FormID, including deleted winners.",
            "live": "Winning records whose record header does not carry the 0x20 deleted flag.",
            "featureCounts": "Computed from live winners; placed-object categories resolve NAME against live base winners.",
            "formIds": "High byte is the zero-based requested load-order owner after each plugin's MAST table is resolved.",
            "craftingCandidateRule": "ACTI EDID contains: "
            + ", ".join(CRAFTING_EDID_TOKENS),
            "scope": "This section counts static plugin records only; runtime-spawned objects and execution paths are not counted.",
        },
        "source": {
            "completeOfficialSet": not missing_official and len(official_actual_names) == len(OFFICIAL_NAMES),
            "fnvrPresent": any(source.role == "helper" for source in sources),
            "warnings": warnings,
        },
        "plugins": per_plugin,
        "corpora": {
            "official": _corpus_summary(
                official_winners, official_physical, unresolvable=official_unresolvable
            ),
            "fnvrLayer": helper_summary,
            "effectiveWithFnvr": _corpus_summary(
                effective_winners, effective_physical, unresolvable=effective_unresolvable
            ),
        },
        "physicalFeatureCounts": {
            "officialRecordsWithSCRI": official_physical_records_with_scri,
            "fnvrRecordsWithSCRI": helper_physical_records_with_scri,
        },
        "baseGameRegression": regression,
        "localDiagnostics": {
            "canonical": False,
            "excludedFromCanonicalSha256": True,
            "inputMode": "openmw-config" if config_path is not None else "explicit",
            "configPath": str(config_path.resolve()) if config_path is not None else None,
            "pluginPaths": [str(source.path) for source in sources],
        },
    }


def validate_strict_official_inputs(
    plugin_paths: Sequence[Path],
    archive_sources: Sequence[ArchiveSource],
    config_sources: OpenMWConfigSources | None = None,
) -> None:
    """Reject every source shape except the frozen official-only corpus."""

    failures: list[str] = []
    plugin_names = [Path(path).name for path in plugin_paths]
    if plugin_names != list(OFFICIAL_NAMES):
        failures.append(
            "requires exactly these plugins in order: "
            + ", ".join(OFFICIAL_NAMES)
            + "; got: "
            + (", ".join(plugin_names) or "<none>")
        )
    archive_names = [source.name for source in archive_sources]
    if archive_names != list(OFFICIAL_ARCHIVE_NAMES):
        failures.append(
            "requires exactly these fallback archives in order: "
            + ", ".join(OFFICIAL_ARCHIVE_NAMES)
            + "; got: "
            + (", ".join(archive_names) or "<none>")
        )

    resolved_input_parents = {
        Path(path).resolve().parent for path in plugin_paths
    } | {source.path.resolve().parent for source in archive_sources}
    if len(resolved_input_parents) != 1:
        failures.append(
            "official inputs must resolve from one data root; got: "
            + ", ".join(sorted(str(path) for path in resolved_input_parents))
        )

    if config_sources is not None:
        if config_sources.content != OFFICIAL_NAMES:
            failures.append(
                "rejects missing, reordered, helper, or extra content entries; got: "
                + ", ".join(config_sources.content)
            )
        if config_sources.fallback_archives != OFFICIAL_ARCHIVE_NAMES:
            failures.append("rejects missing, reordered, or extra fallback archives")
        official_roots = [
            path for kind, path in config_sources.data_entries if kind == "data"
        ]
        local_roots = [
            path for kind, path in config_sources.data_entries if kind == "data-local"
        ]
        nonempty_local_roots = [
            path
            for path in local_roots
            if path.exists() and any(candidate.is_file() for candidate in path.rglob("*"))
        ]
        if len(official_roots) != 1 or nonempty_local_roots:
            rendered = ", ".join(
                f"{kind}={path}" for kind, path in config_sources.data_entries
            )
            failures.append(
                "requires exactly one data= root and permits only empty data-local runtime roots; got: "
                + (rendered or "<none>")
            )
        if len(official_roots) == 1 and len(resolved_input_parents) == 1:
            only_input_root = next(iter(resolved_input_parents))
            if official_roots[0].resolve() != only_input_root:
                failures.append("data root does not own every resolved official input")

    if failures:
        raise CorpusError(
            "Strict official profile rejected input:\n  - " + "\n  - ".join(failures)
        )


def _canonical_report_bytes(report: Mapping) -> bytes:
    canonical = dict(report)
    canonical.pop("localDiagnostics", None)
    canonical.pop("canonicalReportSha256", None)
    return json.dumps(
        canonical,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def finalize_report(report: dict) -> dict:
    """Attach a hash that deliberately excludes all machine-local paths."""

    report["canonicalReportSha256"] = hashlib.sha256(
        _canonical_report_bytes(report)
    ).hexdigest()
    return report


def attach_archive_report(report: dict, archive_report: dict) -> None:
    local = archive_report.pop("localDiagnostics", {})
    report["archives"] = archive_report
    report.setdefault("localDiagnostics", {}).update(local)


def _live_type(official: Mapping, rtype: str) -> int:
    return int(official["recordTypes"].get(rtype, {}).get("live", 0))


def verify_denominators(report: Mapping, denominator_path: Path) -> dict:
    """Verify every census headline this exporter can derive, plus all provenance."""

    try:
        denominator_bytes = denominator_path.read_bytes()
        denominators = json.loads(denominator_bytes)
    except (OSError, json.JSONDecodeError) as error:
        raise CorpusError(f"Cannot read denominator JSON {denominator_path}: {error}") from error
    if denominators.get("schema") != DENOMINATOR_SCHEMA:
        raise CorpusError(
            f"Unexpected denominator schema: {denominators.get('schema')!r}"
        )
    if denominators.get("scopeId") != SCOPE_ID or report.get("scopeId") != SCOPE_ID:
        raise CorpusError("Report and denominator scopeId must both equal the frozen FNV scope")

    failures: list[str] = []
    assertions = 0

    def expect(label: str, actual, expected) -> None:
        nonlocal assertions
        assertions += 1
        if actual != expected:
            failures.append(f"{label}: expected {expected!r}, got {actual!r}")

    source = report["source"]
    expect("source.completeOfficialSet", source["completeOfficialSet"], True)
    expect("source.fnvrPresent", source["fnvrPresent"], False)
    expect("source.warnings", source["warnings"], [])

    expected_plugins = denominators["officialMasters"]
    actual_plugins = report["plugins"]
    expect("plugin count", len(actual_plugins), len(expected_plugins))
    expect(
        "plugin order",
        [plugin["name"] for plugin in actual_plugins],
        [plugin["name"] for plugin in expected_plugins],
    )
    for order, (actual, expected) in enumerate(zip(actual_plugins, expected_plugins)):
        prefix = f"plugin[{order}] {expected['name']}"
        expect(prefix + " role", actual["role"], "official")
        expect(prefix + " loadIndex", actual["loadIndex"], order)
        expect(prefix + " bytes", actual["bytes"], expected["bytes"])
        expect(prefix + " sha256", actual["sha256"].casefold(), expected["sha256"].casefold())
        approved_diagnostics: dict[str, int] = {}
        if actual["sha256"].casefold() == FALLOUTNV_SHA256:
            approved_diagnostics = {"recoveredZlibChecksum:LAND": 1}
        elif actual["sha256"].casefold() == GRA_SHA256:
            approved_diagnostics = {
                "unresolvableRecordFormId:REFR": 1,
                "unresolvableReferencedFormId:REFR.NAME": 1,
            }
        expect(prefix + " payloadDiagnostics", actual["payloadDiagnostics"], approved_diagnostics)

    regression = report.get("baseGameRegression")
    expect("baseGameRegression.status", regression and regression.get("status"), "pass")

    if "archives" not in report:
        failures.append("archives: missing complete official archive report")
    else:
        archives = report["archives"]
        expect("archive source.completeOfficialSet", archives["source"]["completeOfficialSet"], True)
        expect("archive source.warnings", archives["source"]["warnings"], [])
        expected_archives = denominators["officialArchives"]
        actual_archives = archives["archives"]
        expect("archive count", len(actual_archives), len(expected_archives))
        expect(
            "archive order",
            [archive["name"] for archive in actual_archives],
            [archive["name"] for archive in expected_archives],
        )
        for order, (actual, expected) in enumerate(zip(actual_archives, expected_archives)):
            prefix = f"archive[{order}] {expected['name']}"
            expect(prefix + " order", actual["order"], expected["order"])
            expect(prefix + " bytes", actual["bytes"], expected["bytes"])
            expect(prefix + " sha256", actual["sha256"].casefold(), expected["sha256"].casefold())
            expect(prefix + " authoredEntries", actual["authoredEntries"], expected["authoredEntries"])
            expect(
                prefix + " normalizedListingSha256",
                actual["normalizedListingSha256"].casefold(),
                expected["normalizedListingSha256"].casefold(),
            )
        tool = archives["tool"]
        expected_tool_hash = denominators["reproducer"]["bsatoolSha256"].casefold()
        expect("bsatool sha256", tool["sha256"].casefold(), expected_tool_hash)
        expect(
            "bsatool bytes",
            tool["bytes"],
            EXPECTED_BSATOOL_BYTES_BY_SHA256.get(expected_tool_hash),
        )
        expect("bsatool version", tool["versionOutput"], "BSATool version 1.1")
        expect("archive authoredEntries", archives["authoredEntries"], denominators["archives"]["authoredEntries"])
        expect(
            "archive uniqueNormalizedVfsPaths",
            archives["uniqueNormalizedVfsPaths"],
            denominators["archives"]["uniqueNormalizedVfsPaths"],
        )
        expect(
            "archive duplicateOrOverriddenEntries",
            archives["duplicateOrOverriddenEntries"],
            denominators["archives"]["duplicateOrOverriddenEntries"],
        )
        for extension, expected_count in denominators["archives"]["extensions"].items():
            expect(
                f"archive winning extension .{extension}",
                archives["extensionCounts"]["winning"].get(extension, 0),
                expected_count,
            )

    official = report["corpora"]["official"]
    records = official["records"]
    features = official["features"]
    record_den = denominators["recordCorpus"]
    headline_checks = [
        ("recordCorpus.physicalHeadersIncludingTes4", records["physical"] + len(actual_plugins), record_den["physicalHeadersIncludingTes4"]),
        ("recordCorpus.nonTes4Records", records["physical"], record_den["nonTes4Records"]),
        ("recordCorpus.resolvableNonTes4Records", records["physical"] - records["unresolvablePhysicalRecords"], record_den["resolvableNonTes4Records"]),
        ("recordCorpus.unresolvableRecords", records["unresolvablePhysicalRecords"], record_den["unresolvableRecords"]),
        ("recordCorpus.winningRecordsIncludingDeleted", records["winning"], record_den["winningRecordsIncludingDeleted"]),
        ("recordCorpus.winningDeletedRecords", records["deletedWinners"], record_den["winningDeletedRecords"]),
        ("recordCorpus.winningLiveRecords", records["live"], record_den["winningLiveRecords"]),
        ("recordCorpus.rawPlacedReferenceRecords", features["placedRefs"]["physical"], record_den["rawPlacedReferenceRecords"]),
        ("recordCorpus.winningLivePlacedReferences", features["placedRefs"]["live"], record_den["winningLivePlacedReferences"]),
        ("world.cells", features["cells"]["total"], denominators["world"]["cells"]),
        ("world.interiorCells", features["cells"]["interior"], denominators["world"]["interiorCells"]),
        ("world.exteriorCells", features["cells"]["exterior"], denominators["world"]["exteriorCells"]),
        ("world.worldspaces", features["worldSystems"]["WRLD"], denominators["world"]["worldspaces"]),
        ("world.mapMarkers", features["mapMarkers"]["placedRefsXMRK"], denominators["world"]["mapMarkers"]),
        ("placedReferences.doors", features["doors"]["placedRefs"], denominators["placedReferences"]["doors"]),
        ("placedReferences.directedDoorTeleports", features["doors"]["teleportRefsXTEL"], denominators["placedReferences"]["directedDoorTeleports"]),
        ("placedReferences.containers", features["containers"]["placedRefs"], denominators["placedReferences"]["containers"]),
        ("placedReferences.npcs", features["actors"]["ACHR"], denominators["placedReferences"]["npcs"]),
        ("placedReferences.creatures", features["actors"]["ACRE"], denominators["placedReferences"]["creatures"]),
        ("placedReferences.terminals", features["terminals"]["placedRefs"], denominators["placedReferences"]["terminals"]),
        ("placedReferences.craftingStationsCandidate", features["craftingCandidates"]["placedCandidateRefs"], denominators["placedReferences"]["craftingStationsCandidate"]),
        ("placedReferences.craftingStationCandidateBases", features["craftingCandidates"]["candidateBaseRecords"], denominators["placedReferences"]["craftingStationCandidateBases"]),
        ("placedReferences.radios", features["radios"]["placedRadioRefs"], denominators["placedReferences"]["radios"]),
        ("placedReferences.activatorsAndTalkingActivators", features["activators"]["placedRefs"], denominators["placedReferences"]["activatorsAndTalkingActivators"]),
        ("placedReferences.engineReservedMarkerBaseReferences", features["engineReservedMarkers"]["placedRefs"], denominators["placedReferences"]["engineReservedMarkerBaseReferences"]),
        ("dialogue.topics", features["dialogue"]["topicsDIAL"], denominators["dialogue"]["topics"]),
        ("dialogue.infos", features["dialogue"]["infosINFO"], denominators["dialogue"]["infos"]),
        ("dialogue.responses", features["dialogue"]["responsesTRDT"], denominators["dialogue"]["responses"]),
        ("dialogue.conditions", features["dialogue"]["conditions"]["total"], denominators["dialogue"]["conditions"]),
        ("dialogue.choiceEdges", features["dialogue"]["choiceEdgesTCLT"], denominators["dialogue"]["choiceEdges"]),
        ("questsAndScripts.officialQuests", features["quests"]["recordsQUST"], denominators["questsAndScripts"]["officialQuests"]),
        ("questsAndScripts.questStages", features["quests"]["stagesINDX"], denominators["questsAndScripts"]["questStages"]),
        ("questsAndScripts.questStageEntries", features["quests"]["stageEntriesQSDT"], denominators["questsAndScripts"]["questStageEntries"]),
        ("questsAndScripts.questObjectives", features["quests"]["objectivesQOBJ"], denominators["questsAndScripts"]["questObjectives"]),
        ("questsAndScripts.questObjectiveTargets", features["quests"]["objectiveTargetsQSTA"], denominators["questsAndScripts"]["questObjectiveTargets"]),
        ("questsAndScripts.officialStandaloneScripts", features["scripts"]["recordsSCPT"], denominators["questsAndScripts"]["officialStandaloneScripts"]),
        ("questsAndScripts.physicalRecordsWithScriptAttachments", report["physicalFeatureCounts"]["officialRecordsWithSCRI"], denominators["questsAndScripts"]["physicalRecordsWithScriptAttachments"]),
        ("questsAndScripts.winningLiveRecordsWithScriptAttachments", features["scripts"]["recordsWithSCRI"], denominators["questsAndScripts"]["winningLiveRecordsWithScriptAttachments"]),
        ("questsAndScripts.aiPackages", features["worldSystems"]["PACK"], denominators["questsAndScripts"]["aiPackages"]),
        ("questsAndScripts.leveledNpcLists", _live_type(official, "LVLN"), denominators["questsAndScripts"]["leveledNpcLists"]),
        ("questsAndScripts.leveledCreatureLists", _live_type(official, "LVLC"), denominators["questsAndScripts"]["leveledCreatureLists"]),
        ("interactiveRecords.terminalBases", features["terminals"]["baseRecordsTERM"], denominators["interactiveRecords"]["terminalBases"]),
        ("interactiveRecords.terminalMenuItems", features["terminals"]["menuItemsITXT"], denominators["interactiveRecords"]["terminalMenuItems"]),
        ("interactiveRecords.weatherRecords", features["worldSystems"]["WTHR"], denominators["interactiveRecords"]["weatherRecords"]),
        ("interactiveRecords.climates", features["worldSystems"]["CLMT"], denominators["interactiveRecords"]["climates"]),
        ("interactiveRecords.regions", features["worldSystems"]["REGN"], denominators["interactiveRecords"]["regions"]),
        ("interactiveRecords.encounterZones", features["worldSystems"]["ECZN"], denominators["interactiveRecords"]["encounterZones"]),
    ]
    runtime_type_map = {
        "authoredNavmeshes": "NAVM", "leveledItems": "LVLI", "magicEffects": "MGEF",
        "enchantments": "ENCH", "spells": "SPEL", "effectShaders": "EFSH",
        "perks": "PERK", "actorValues": "AVIF", "factions": "FACT",
        "challenges": "CHAL", "recipes": "RCPE", "messages": "MESG",
        "imageSpaces": "IMGS", "imageSpaceAdapters": "IMAD", "waterTypes": "WATR",
        "projectiles": "PROJ", "explosions": "EXPL", "impactData": "IPCT",
        "impactDataSets": "IPDS", "sounds": "SOUN", "musicTypes": "MUSC",
    }
    for denominator_name, rtype in runtime_type_map.items():
        headline_checks.append(
            (
                f"runtimeRecordFamilies.{denominator_name}",
                _live_type(official, rtype),
                denominators["runtimeRecordFamilies"][denominator_name],
            )
        )
    headline_checks.append(
        (
            "runtimeRecordFamilies.placedWaterTypes",
            _live_type(official, "PWAT"),
            denominators["runtimeRecordFamilies"]["placedWaterTypes"],
        )
    )
    for label, actual, expected in headline_checks:
        expect(label, actual, expected)

    helper_records = report["corpora"]["fnvrLayer"]["records"]
    expect("strict fnvrLayer physical records", helper_records["physical"], 0)
    expect("strict fnvrLayer winning records", helper_records["winning"], 0)

    if failures:
        rendered = "\n  - ".join(failures[:50])
        suffix = "" if len(failures) <= 50 else f"\n  - ... {len(failures) - 50} more"
        raise CorpusError(
            f"Denominator verification failed ({len(failures)} mismatch(es)):\n  - {rendered}{suffix}"
        )
    return {
        "status": "pass",
        "scopeId": SCOPE_ID,
        "denominatorSchema": DENOMINATOR_SCHEMA,
        "denominatorSha256": hashlib.sha256(denominator_bytes).hexdigest(),
        "assertionsPassed": assertions,
    }


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=repo_root / "profiles" / "fallout_new_vegas" / "openmw.cfg",
        help="OpenMW config used for data/content resolution (default: project FNV profile)",
    )
    parser.add_argument(
        "--plugin",
        action="append",
        type=Path,
        default=[],
        help="Explicit plugin path in load order; repeat to bypass --config",
    )
    parser.add_argument(
        "--archive",
        action="append",
        type=Path,
        default=[],
        help="Explicit official BSA path in fallback order; repeat with --plugin",
    )
    parser.add_argument(
        "--bsatool",
        type=Path,
        default=repo_root / "local" / "openmw-fo4guard" / "bsatool.exe",
        help="Read-only BSA listing tool (default: repo-local OpenMW bsatool)",
    )
    parser.add_argument(
        "--skip-archives",
        action="store_true",
        help="Export plugin records only; explicit --plugin inputs already imply this",
    )
    parser.add_argument(
        "--strict-official-profile",
        action="store_true",
        help="Reject helper plugins, overlays, extra/missing/reordered inputs, and split data roots",
    )
    parser.add_argument(
        "--verify-denominators",
        type=Path,
        help="Fail unless provenance, listings, diagnostics, and derived counts match this JSON",
    )
    parser.add_argument("--output", type=Path, help="Write JSON here instead of stdout")
    parser.add_argument("--compact", action="store_true", help="Emit single-line JSON")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.archive and not args.plugin:
            raise CorpusError("Explicit --archive inputs require explicit --plugin inputs")
        if args.skip_archives and args.archive:
            raise CorpusError("--skip-archives cannot be combined with --archive")

        config_sources: OpenMWConfigSources | None = None
        if args.plugin:
            config_path = None
            paths = [path.resolve() for path in args.plugin]
            archive_sources = [
                ArchiveSource(path.name, path.resolve()) for path in args.archive
            ]
        else:
            config_path = args.config
            config_sources = read_openmw_config_sources(args.config)
            paths = _resolve_config_entries(
                config_sources.content, config_sources.data_roots, "content"
            )
            archive_sources = (
                []
                if args.skip_archives
                else [
                    ArchiveSource(name, path)
                    for name, path in zip(
                        config_sources.fallback_archives,
                        _resolve_config_entries(
                            config_sources.fallback_archives,
                            config_sources.data_roots,
                            "fallback-archive",
                        ),
                        strict=True,
                    )
                ]
            )

        strict = args.strict_official_profile or args.verify_denominators is not None
        if strict:
            if args.skip_archives or not archive_sources:
                raise CorpusError(
                    "Strict official verification requires all explicit/configured official archives"
                )
            validate_strict_official_inputs(paths, archive_sources, config_sources)

        report = build_report(paths, config_path=config_path)
        if archive_sources:
            archive_report = build_archive_report(
                archive_sources,
                args.bsatool,
                repo_root=Path(__file__).resolve().parents[1],
            )
            attach_archive_report(report, archive_report)
        if args.verify_denominators is not None:
            report["verification"] = verify_denominators(
                report, args.verify_denominators.resolve()
            )
            report["localDiagnostics"]["denominatorPath"] = str(
                args.verify_denominators.resolve()
            )
        finalize_report(report)
    except (CorpusError, OSError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    text = json.dumps(
        report,
        ensure_ascii=False,
        separators=(",", ":") if args.compact else None,
        indent=None if args.compact else 2,
    ) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
