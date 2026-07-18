#!/usr/bin/env python3
"""Export a reproducible Fallout: New Vegas retail-corpus denominator.

This is deliberately a static reader.  It never starts Fallout or OpenMW and
never extracts archive contents.  Plugin counts use TES4-family record headers
after master-aware FormID resolution and load-order override/deletion handling.
Archive counts use OpenMW's ``bsatool list`` command against the configured
fallback archives.
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
            data_roots.append(_config_path(value, config_path.parent))
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
                "path": str(source.path.resolve()),
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
            "path": str(bsatool_path),
            "bytes": bsatool_path.stat().st_size,
            "sha256": _sha256_file(bsatool_path),
            "versionOutput": version_output,
            "repoLocal": repo_local,
            "listingInvocation": ["bsatool", "list", "<archive-path>"],
        },
        **aggregate,
        "archives": archive_metadata,
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
        # One retail GRA REFR is authored with local index 02 despite GRA
        # declaring only FalloutNV.esm as index 00.  It belongs in the
        # physical-header denominator but cannot safely participate in an
        # override chain.  Keep it explicit rather than guessing ownership.
        form_id = None
        if diagnostics is not None:
            diagnostics[f"unresolvableRecordFormId:{rtype}"] += 1

    metrics: Counter[str] = Counter()
    base: int | None = None
    editor_id = ""
    full_name = ""
    cell_flags: int | None = None
    want_names = rtype in ("FURN", "ACTI", "TACT")
    context = f"{source.name}:{rtype}:0x{raw_form:08x}"
    for name, offset, size in _subrecords(payload_data, payload_start, payload_end, context):
        if name in COUNTED_SUBRECORDS:
            metrics[name.decode("ascii")] += 1
        if rtype in PLACED_TYPES and name == b"NAME" and size >= 4:
            try:
                base = _resolve_form_id(
                    _u32(payload_data, offset), source, master_indices, f"{rtype}.NAME"
                )
            except CorpusError:
                base = None
                if diagnostics is not None:
                    diagnostics[f"unresolvableReferencedFormId:{rtype}.NAME"] += 1
        elif want_names and name == b"EDID":
            editor_id = _zstr(payload_data[offset : offset + size])
        elif want_names and name == b"FULL" and not source.localized:
            full_name = _zstr(payload_data[offset : offset + size])
        elif rtype == "CELL" and name == b"DATA" and size >= 1:
            cell_flags = payload_data[offset]

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
                            # The installed retail FalloutNV.esm contains a LAND
                            # whose deflate stream is complete but whose trailing
                            # Adler-32 is wrong.  Recover only that narrowly
                            # recognizable case and expose it in diagnostics.
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
    infos = [record for record in live if record.rtype == "INFO"]
    quests = [record for record in live if record.rtype == "QUST"]
    terminal_records = [record for record in live if record.rtype == "TERM"]
    script_links = [record for record in live if record.count("SCRI")]
    cells = [record for record in live if record.rtype == "CELL"]

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
                    if record.form_id is not None:
                        official_winners[record.form_id] = record
                    else:
                        official_unresolvable += 1
                else:
                    helper_physical[record.rtype] += 1
                    if record.form_id is not None:
                        helper_winners[record.form_id] = record
                    else:
                        helper_unresolvable += 1
        per_plugin.append(
            {
                "loadIndex": source.load_index,
                "name": source.name,
                "role": source.role,
                "path": str(source.path),
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
        "schema": "nikami-fnv-parity-corpus/v1",
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
            "config": str(config_path.resolve()) if config_path is not None else None,
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
        "baseGameRegression": regression,
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
    parser.add_argument("--output", type=Path, help="Write JSON here instead of stdout")
    parser.add_argument("--compact", action="store_true", help="Emit single-line JSON")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        config_path = None if args.plugin else args.config
        paths = [path.resolve() for path in args.plugin] if args.plugin else plugin_paths_from_config(args.config)
        report = build_report(paths, config_path=config_path)
        if config_path is not None and not args.skip_archives:
            archive_sources = archive_sources_from_config(config_path)
            report["archives"] = build_archive_report(
                archive_sources,
                args.bsatool,
                repo_root=Path(__file__).resolve().parents[1],
            )
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
