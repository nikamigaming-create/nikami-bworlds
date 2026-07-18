#!/usr/bin/env python3
"""Inventory the frozen retail Fallout: New Vegas GECK workload.

This is a static, path-independent plugin reader.  It reuses the canonical
corpus scanner for plugin discovery, master resolution, record identity, and
the two byte-identity-locked retail recoveries.  It never starts or controls a
game, desktop, or browser and never extracts an archive.

The detailed inventory covers winning official records only.  Physical and
deleted/overridden records remain explicit parser denominators.  Any unknown
script/condition structure is preserved as a parse-anomaly row, marks the
report incomplete, and causes the CLI to return nonzero unless the caller
explicitly requests an incomplete diagnostic report.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import re
import struct
import sys
import zlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence

import export_fnv_parity_corpus as corpus


SCHEMA = "nikami-fnv-geck-workload/v1"
SCOPE_ID = corpus.SCOPE_ID

# This pins the inventory to the same English Ultimate Edition byte corpus as
# catalog/fnv-parity-denominators.json.  Synthetic callers can disable the
# complete-scope contract without weakening the default CLI.
EXPECTED_OFFICIAL = {
    "FalloutNV.esm": (245_650_747, "50991d36804b7d1e70df1afd7471b72f0e29d1b456ee2516a9717c002564e7c1"),
    "DeadMoney.esm": (6_274_851, "31ede9c21ae6960ec868bf60879c602bf7a13879b2f47e7cfd1ac30b4d4de329"),
    "HonestHearts.esm": (17_308_500, "4341d1a35eaac7d9e7097ebac8f31a13264ca6dcb33443408bd97e5ddd5d8368"),
    "OldWorldBlues.esm": (16_202_800, "fd6cc6e582582ec035277150e106d12b6d78c7c60cbb506545e06d1fa7212295"),
    "LonesomeRoad.esm": (25_676_818, "41bf457c1ed313834407840d2b60447f74264e33b372590454ead8ac663b0516"),
    "GunRunnersArsenal.esm": (252_445, "aee27930699494f0626d24a3a8ae947fe447e33edc0ed46762e54faab4c05a1e"),
    "CaravanPack.esm": (3_007, "0473cff52d375a77d6585f203a914445fa5a9e6ba726818aa7d8d48cb177ec82"),
    "ClassicPack.esm": (6_523, "3b31928dfdac46028f2e12f25b0dbdd0e809d4d74ac04fb7783e0063e912760b"),
    "MercenaryPack.esm": (3_064, "73e76bcadbf326818af7b58c315773a2d86fe3a8186a778e84a68916cb830c59"),
    "TribalPack.esm": (2_323, "342f42ce9835f57ee19be09f12ad0ba2c6182e86740338202fcea9011d62f328"),
}

DISPOSITIONS = (
    "existing-cpp-analog",
    "new-cpp-runtime",
    "lua-retail-script",
    "data-only",
    "retail-unreachable",
    "uncovered",
)

PRIMARY_RECORD_TYPES = frozenset({"SCPT", "QUST", "DIAL", "INFO", "TERM", "PACK"})
EFFECT_RECORD_TYPES = frozenset({"MGEF", "ENCH", "SPEL", "INGR", "ALCH"})
SELECTED_RECORD_TYPES = PRIMARY_RECORD_TYPES | EFFECT_RECORD_TYPES
SCRIPT_SUBRECORDS = frozenset({b"SCHR", b"SCDA", b"SCTX", b"SCRO", b"SCRV", b"SLSD", b"SCVR"})
INTERESTING_SUBRECORDS = SCRIPT_SUBRECORDS | frozenset({b"SCRI", b"CTDA", b"CTDT"})

RUN_ON_NAMES = {
    0: "subject",
    1: "target",
    2: "reference",
    3: "combat-target",
    4: "linked-reference",
}
ENGINE_RESERVED_FORM_IDS = {
    0x00000014: "player-reference",
}
STATEMENT_NAMES = {
    0x10: "begin",
    0x11: "end",
    0x12: "short",
    0x13: "long",
    0x14: "float",
    0x15: "set-to",
    0x16: "if",
    0x17: "else",
    0x18: "elseif",
    0x19: "endif",
    0x1C: "reference-function-wrapper",
    0x1D: "script-name",
    0x1E: "return",
    0x1F: "ref",
}

SOURCE_KEYWORDS = frozenset(
    {
        "begin",
        "else",
        "elseif",
        "end",
        "endif",
        "float",
        "if",
        "long",
        "ref",
        "return",
        "scn",
        "scriptname",
        "set",
        "short",
        "to",
    }
)
DECLARATION_KEYWORDS = frozenset({"short", "long", "float", "ref"})
TOKEN_RE = re.compile(
    r"(?P<space>[ \t\r\n]+)"
    r"|(?P<comment>;[^\r\n]*)"
    r'|(?P<string>"(?:""|[^"\r\n])*")'
    r"|(?P<number>(?:0[xX][0-9A-Fa-f]+)|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"|(?P<identifier>[A-Za-z_][A-Za-z0-9_]*)"
    r"|(?P<operator>==|!=|<=|>=|&&|\|\||:=|\+=|-=|\*=|/=)"
    r"|(?P<symbol>.)",
    re.DOTALL,
)


class InventoryError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class RawRecord:
    offset: int
    rtype: str
    raw_form_id: int
    flags: int
    payload: bytes


@dataclass(frozen=True, slots=True)
class Token:
    kind: str
    value: str
    normalized: str


def _u16(data: bytes | mmap.mmap, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes | mmap.mmap, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _hex32(value: int | None) -> str | None:
    return None if value is None else f"0x{value:08x}"


def _record_id(form_id: int) -> str:
    return f"form:{form_id:08x}"


def _artifact_id(form_id: int, kind: str, ordinal: int) -> str:
    return f"{_record_id(form_id)}:{kind}:{ordinal}"


def _canonical_digest(report: Mapping) -> str:
    encoded = json.dumps(
        report, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _anomaly(
    anomalies: list[dict],
    *,
    plugin: str,
    rtype: str,
    raw_form_id: int,
    record_offset: int,
    code: str,
    detail: str,
) -> None:
    anomalies.append(
        {
            "plugin": plugin,
            "recordType": rtype,
            "rawFormId": _hex32(raw_form_id),
            "recordOffset": f"0x{record_offset:08x}",
            "code": code,
            "detail": detail,
        }
    )


def _iter_subrecords(payload: bytes, context: str) -> Iterator[tuple[bytes, bytes]]:
    """Strictly iterate TES4-family subrecords, including XXXX sizes."""

    offset = 0
    extended_size: int | None = None
    while offset < len(payload):
        if offset + 6 > len(payload):
            raise InventoryError(f"Truncated subrecord header in {context} at 0x{offset:x}")
        name = payload[offset : offset + 4]
        size = _u16(payload, offset + 4)
        offset += 6
        if name == b"XXXX":
            if extended_size is not None:
                raise InventoryError(f"Nested XXXX subrecord in {context} at 0x{offset - 6:x}")
            if size < 4 or offset + size > len(payload):
                raise InventoryError(f"Malformed XXXX subrecord in {context} at 0x{offset - 6:x}")
            extended_size = _u32(payload, offset)
            offset += size
            continue
        actual_size = extended_size if extended_size is not None else size
        extended_size = None
        if offset + actual_size > len(payload):
            raise InventoryError(
                f"Subrecord {name!r} overruns {context}: "
                f"0x{offset:x}+{actual_size} > 0x{len(payload):x}"
            )
        yield name, payload[offset : offset + actual_size]
        offset += actual_size
    if extended_size is not None:
        raise InventoryError(f"Dangling XXXX subrecord in {context}")


def _iter_raw_plugin_records(source: corpus.PluginSource) -> Iterator[RawRecord]:
    """Yield raw payloads in the same record order as the corpus scanner."""

    with source.path.open("rb") as stream, mmap.mmap(
        stream.fileno(), 0, access=mmap.ACCESS_READ
    ) as data:
        first_end = source.header_size + _u32(data, 4)
        if first_end > len(data):
            raise InventoryError(f"TES4 header overruns {source.name}")

        def walk(start: int, end: int) -> Iterator[RawRecord]:
            offset = start
            while offset < end:
                if offset + source.header_size > end:
                    raise InventoryError(
                        f"Truncated record header in {source.name} at 0x{offset:x}"
                    )
                signature = bytes(data[offset : offset + 4])
                if signature == b"GRUP":
                    group_size = _u32(data, offset + 4)
                    group_end = offset + group_size
                    if group_size < source.header_size or group_end > end:
                        raise InventoryError(
                            f"Malformed GRUP in {source.name} at 0x{offset:x}"
                        )
                    yield from walk(offset + source.header_size, group_end)
                    offset = group_end
                    continue

                try:
                    rtype = signature.decode("ascii")
                except UnicodeDecodeError as error:
                    raise InventoryError(
                        f"Invalid record signature in {source.name} at 0x{offset:x}"
                    ) from error
                payload_size = _u32(data, offset + 4)
                flags = _u32(data, offset + 8)
                raw_form_id = _u32(data, offset + 12)
                payload_start = offset + source.header_size
                payload_end = payload_start + payload_size
                if payload_end > end:
                    raise InventoryError(
                        f"{rtype} record overruns {source.name} at 0x{offset:x}"
                    )

                if flags & corpus.REC_COMPRESSED:
                    if payload_size < 4:
                        raise InventoryError(
                            f"Compressed {rtype} is too short in {source.name} at 0x{offset:x}"
                        )
                    expected_size = _u32(data, payload_start)
                    packed = bytes(data[payload_start + 4 : payload_end])
                    try:
                        payload = zlib.decompress(packed)
                    except zlib.error as error:
                        recovery_key = (source.sha256, offset, rtype, raw_form_id)
                        if recovery_key not in corpus.ALLOWED_ZLIB_CHECKSUM_RECOVERIES:
                            raise InventoryError(
                                f"Cannot decompress {rtype} in {source.name} at 0x{offset:x}: {error}"
                            ) from error
                        try:
                            payload = zlib.decompress(packed[2:-4], -15)
                        except zlib.error as recovery_error:
                            raise InventoryError(
                                f"Raw-deflate recovery failed for {rtype} in {source.name} "
                                f"at 0x{offset:x}: {recovery_error}"
                            ) from error
                    if len(payload) != expected_size:
                        raise InventoryError(
                            f"Decompressed size mismatch for {rtype} in {source.name} "
                            f"at 0x{offset:x}: {len(payload)} != {expected_size}"
                        )
                else:
                    payload = bytes(data[payload_start:payload_end])

                yield RawRecord(offset, rtype, raw_form_id, flags, payload)
                offset = payload_end

        yield from walk(first_end, len(data))


def _resolve_authored_form_id(
    raw: int,
    source: corpus.PluginSource,
    by_name: Mapping[str, corpus.PluginSource],
) -> int | None:
    if raw == 0:
        return None
    local_index = raw >> 24
    object_id = raw & 0x00FFFFFF
    if local_index < len(source.masters):
        owner = by_name[source.masters[local_index].casefold()].load_index
    elif local_index == len(source.masters):
        owner = source.load_index
    else:
        raise InventoryError(
            f"Invalid local FormID {_hex32(raw)} in {source.name}; "
            f"plugin has {len(source.masters)} masters"
        )
    return (owner << 24) | object_id


def _tokenize(source_text: str) -> list[Token]:
    tokens: list[Token] = []
    offset = 0
    while offset < len(source_text):
        match = TOKEN_RE.match(source_text, offset)
        if match is None:
            raise InventoryError(f"Tokenizer made no progress at source character {offset}")
        offset = match.end()
        kind = match.lastgroup
        assert kind is not None
        value = match.group(kind)
        if kind in ("space", "comment"):
            continue
        if kind == "identifier":
            normalized = value.casefold()
        elif kind == "string":
            normalized = "sha256:" + hashlib.sha256(value.encode("cp1252")).hexdigest()
        else:
            normalized = value.casefold()
        tokens.append(Token(kind, value, normalized))
    return tokens


def _line_tokens(source_text: str) -> list[list[Token]]:
    return [_tokenize(line) for line in source_text.splitlines()]


def _source_command_candidates(source_text: str) -> list[tuple[str, str]]:
    """Return conservative lexical command/event candidates.

    This deliberately does not claim semantic command resolution.  The source
    token, compiled opcode, and eventual retail command table remain separate
    ledgers until a VM slice binds them with differential evidence.
    """

    lines = _line_tokens(source_text)
    declared: set[str] = set()
    for tokens in lines:
        identifiers = [token.normalized for token in tokens if token.kind == "identifier"]
        if len(identifiers) >= 2 and identifiers[0] in DECLARATION_KEYWORDS:
            declared.add(identifiers[1])

    candidates: list[tuple[str, str]] = []
    for tokens in lines:
        ids = [(index, token.normalized) for index, token in enumerate(tokens) if token.kind == "identifier"]
        if not ids:
            continue
        first_index, first = ids[0]
        seen: set[tuple[str, str]] = set()

        def add(value: str, role: str) -> None:
            item = (value, role)
            if value not in SOURCE_KEYWORDS and value not in declared and item not in seen:
                candidates.append(item)
                seen.add(item)

        # Dot calls are the least ambiguous lexical command positions.
        for index, value in ids:
            if index >= 1 and tokens[index - 1].value == ".":
                add(value, "reference-call")

        if first in ("scn", "scriptname") or first in DECLARATION_KEYWORDS:
            continue
        if first == "begin":
            if len(ids) >= 2:
                add(ids[1][1], "event-block")
            continue
        if first in ("if", "elseif"):
            if len(ids) >= 2:
                add(ids[1][1], "condition-expression")
            continue
        if first == "set":
            to_position = next(
                (index for index, value in ids if value == "to"), None
            )
            if to_position is not None:
                rhs = next(
                    (value for index, value in ids if index > to_position), None
                )
                if rhs is not None:
                    add(rhs, "assignment-expression")
            continue
        if first not in SOURCE_KEYWORDS:
            # A statement may be "ref.Command ...".  Dot handling above has
            # already emitted Command, so do not mislabel the reference name.
            has_dot_after_first = (
                first_index + 1 < len(tokens) and tokens[first_index + 1].value == "."
            )
            if not has_dot_after_first:
                add(first, "statement")
    return candidates


def _parse_compiled_frames(data: bytes) -> list[dict]:
    """Parse retail line framing documented by the local xNVSE analyzer."""

    frames: list[dict] = []
    offset = 0
    while offset < len(data):
        start = offset
        if offset + 4 > len(data):
            raise InventoryError(
                f"Compiled line header is truncated at byte {offset} of {len(data)}"
            )
        outer_opcode = _u16(data, offset)
        if outer_opcode == 0x1C:
            if offset + 8 > len(data):
                raise InventoryError(
                    f"Compiled reference-function header is truncated at byte {offset}"
                )
            calling_ref = _u16(data, offset + 2)
            opcode = _u16(data, offset + 4)
            length = _u16(data, offset + 6)
            header_size = 8
        else:
            calling_ref = None
            opcode = outer_opcode
            length = _u16(data, offset + 2)
            header_size = 4
        payload_start = offset + header_size
        payload_end = payload_start + length
        if payload_end > len(data):
            raise InventoryError(
                f"Compiled opcode 0x{opcode:04x} at byte {offset} overruns SCDA: "
                f"{payload_end} > {len(data)}"
            )
        frame = {
            "offset": start,
            "opcode": f"0x{opcode:04x}",
            "statement": STATEMENT_NAMES.get(opcode),
            "payloadBytes": length,
            "referenceFunction": outer_opcode == 0x1C,
            "callingReferenceIndex": calling_ref,
        }
        if opcode == 0x10:
            if length < 6:
                raise InventoryError(
                    f"Begin statement at byte {offset} has {length} payload bytes; expected at least 6"
                )
            frame["eventOpcode"] = f"0x{_u16(data, payload_start):04x}"
        frames.append(frame)
        offset = payload_end
    return frames


def _decode_sctx(payload: bytes) -> tuple[str, bool]:
    terminated = payload.endswith(b"\0")
    body = payload.rstrip(b"\0")
    if b"\0" in body:
        raise InventoryError("SCTX contains an embedded NUL byte")
    text = body.decode("cp1252")
    bad_controls = sorted(
        {ord(char) for char in text if ord(char) < 0x20 and char not in "\t\r\n"}
    )
    if bad_controls:
        raise InventoryError(
            "SCTX contains unsupported control bytes: "
            + ", ".join(f"0x{value:02x}" for value in bad_controls)
        )
    return text, terminated


def _segment_context(
    rtype: str,
    *,
    info_end: bool,
    quest_stage: int | None,
    quest_entry: int | None,
    terminal_item: int | None,
    package_event: str | None,
) -> str:
    if rtype == "SCPT":
        return "standalone"
    if rtype == "INFO":
        return "end" if info_end else "begin"
    if rtype == "QUST" and quest_stage is not None and quest_entry is not None:
        return f"stage:{quest_stage}:entry:{quest_entry}"
    if rtype == "TERM" and terminal_item is not None:
        return f"menu-item:{terminal_item}"
    if rtype == "PACK" and package_event is not None:
        return f"package-event:{package_event}"
    return "embedded"


def _parse_condition(payload: bytes) -> dict:
    if len(payload) not in (20, 24, 28, 36):
        raise InventoryError(
            f"CTDA/CTDT has {len(payload)} bytes; expected 20, 24, 28, or 36"
        )
    condition = _u32(payload, 0)
    comparison_bits = _u32(payload, 4)
    function_word = _u32(payload, 8)
    param1 = _u32(payload, 12)
    param2 = _u32(payload, 16)
    param3: int | None = None
    if len(payload) == 20:
        run_on = 0
        reference = 0
        authored_run_on = False
    elif len(payload) == 24:
        run_on = _u32(payload, 20)
        reference = 0
        authored_run_on = True
    elif len(payload) == 28:
        run_on = _u32(payload, 20)
        reference = _u32(payload, 24)
        authored_run_on = True
    else:
        param3 = _u32(payload, 20)
        run_on = _u32(payload, 24)
        reference = _u32(payload, 28)
        authored_run_on = True
    return {
        "bytes": len(payload),
        "operatorAndFlags": f"0x{condition:08x}",
        "comparisonBits": f"0x{comparison_bits:08x}",
        "comparisonUsesGlobal": bool(condition & 0x04),
        "functionId": function_word & 0xFFFF,
        "functionWordHigh": function_word >> 16,
        "param1Raw": _hex32(param1),
        "param2Raw": _hex32(param2),
        "param3Raw": _hex32(param3),
        "runOn": run_on,
        "runOnName": RUN_ON_NAMES.get(run_on, f"unknown:{run_on}"),
        "authoredRunOn": authored_run_on,
        "referenceRaw": _hex32(reference),
        "_comparisonRaw": comparison_bits if condition & 0x04 else 0,
        "_referenceRaw": reference,
    }


def _parse_record_candidate(
    source: corpus.PluginSource,
    fact: corpus.RecordFacts,
    raw: RawRecord,
    anomalies: list[dict],
) -> dict | None:
    context = f"{source.name}:{raw.rtype}:{_hex32(raw.raw_form_id)}"
    try:
        subrecords = list(_iter_subrecords(raw.payload, context))
    except InventoryError as error:
        _anomaly(
            anomalies,
            plugin=source.name,
            rtype=raw.rtype,
            raw_form_id=raw.raw_form_id,
            record_offset=raw.offset,
            code="subrecord-structure",
            detail=str(error),
        )
        return None

    is_selected = raw.rtype in SELECTED_RECORD_TYPES
    is_artifact_owner = any(name in INTERESTING_SUBRECORDS for name, _ in subrecords)
    if not is_selected and not is_artifact_owner:
        return None

    editor_id = ""
    attachments: list[dict] = []
    conditions: list[dict] = []
    segments: list[dict] = []
    current: dict | None = None
    info_end = False
    quest_stage: int | None = None
    quest_entry: int | None = None
    quest_entry_count: Counter[int] = Counter()
    terminal_item: int | None = None
    package_event: str | None = None

    def record_anomaly(code: str, detail: str) -> None:
        _anomaly(
            anomalies,
            plugin=source.name,
            rtype=raw.rtype,
            raw_form_id=raw.raw_form_id,
            record_offset=raw.offset,
            code=code,
            detail=detail,
        )

    def finish_segment() -> None:
        nonlocal current
        if current is None:
            return
        header = current.get("header")
        compiled = current["compiled"]
        if header is None:
            record_anomaly("script-missing-schr", "Script data appeared without a SCHR header")
        else:
            authored_size = header["compiledSize"]
            actual_size = sum(item["bytes"] for item in compiled)
            if authored_size != actual_size:
                record_anomaly(
                    "script-compiled-size",
                    f"SCHR compiledSize {authored_size} != SCDA bytes {actual_size}",
                )
            authored_refs = header["referenceCount"]
            actual_refs = len(current["references"]) + len(current["referenceVariables"])
            if authored_refs != actual_refs:
                if authored_refs > actual_refs and header["compiledSize"] == 0:
                    # Three frozen source-only result scripts declare reference
                    # slots that are not materialized as SCRO/SCRV subrecords.
                    # Their structure is understood, but the missing slots must
                    # remain explicit unresolved workload rather than being
                    # mistaken for a binary parse failure.
                    current["unmaterializedReferenceSlots"] = authored_refs - actual_refs
                else:
                    record_anomaly(
                        "script-reference-count",
                        f"SCHR referenceCount {authored_refs} != SCRO+SCRV count {actual_refs}",
                    )
        if len(compiled) > 1:
            record_anomaly("script-multiple-scda", f"Script segment contains {len(compiled)} SCDA blobs")
        if len(current["sources"]) > 1:
            record_anomaly(
                "script-multiple-sctx", f"Script segment contains {len(current['sources'])} SCTX blobs"
            )
        segments.append(current)
        current = None

    for name, payload in subrecords:
        if name == b"EDID":
            editor_id = payload.split(b"\0", 1)[0].decode("cp1252")
            continue
        if name == b"NEXT" and raw.rtype == "INFO":
            finish_segment()
            info_end = True
            continue
        if name == b"INDX" and raw.rtype == "QUST":
            finish_segment()
            if len(payload) == 2:
                quest_stage = struct.unpack("<h", payload)[0]
                quest_entry = None
            else:
                quest_stage = None
                quest_entry = None
            continue
        if name == b"QSDT" and raw.rtype == "QUST":
            finish_segment()
            if quest_stage is not None:
                quest_entry_count[quest_stage] += 1
                quest_entry = quest_entry_count[quest_stage] - 1
            continue
        if name == b"QOBJ" and raw.rtype == "QUST":
            finish_segment()
            quest_stage = None
            quest_entry = None
            continue
        if name == b"ITXT" and raw.rtype == "TERM":
            finish_segment()
            terminal_item = 0 if terminal_item is None else terminal_item + 1
            continue
        if name in (b"POBA", b"POEA", b"POCA") and raw.rtype == "PACK":
            finish_segment()
            package_event = {b"POBA": "begin", b"POEA": "end", b"POCA": "change"}[name]
            continue

        if name == b"SCRI":
            if len(payload) != 4:
                record_anomaly("scri-size", f"SCRI has {len(payload)} bytes; expected 4")
            else:
                attachments.append({"targetRaw": _hex32(_u32(payload, 0)), "_targetRaw": _u32(payload, 0)})
            continue
        if name in (b"CTDA", b"CTDT"):
            try:
                condition = _parse_condition(payload)
            except InventoryError as error:
                record_anomaly("condition-structure", str(error))
            else:
                condition["subrecord"] = name.decode("ascii")
                conditions.append(condition)
            continue

        if name == b"SCHR":
            finish_segment()
            current = {
                "context": _segment_context(
                    raw.rtype,
                    info_end=info_end,
                    quest_stage=quest_stage,
                    quest_entry=quest_entry,
                    terminal_item=terminal_item,
                    package_event=package_event,
                ),
                "header": None,
                "compiled": [],
                "sources": [],
                "references": [],
                "referenceVariables": [],
                "locals": [],
                "unmaterializedReferenceSlots": 0,
            }
            if len(payload) != 20:
                record_anomaly("schr-size", f"SCHR has {len(payload)} bytes; expected 20")
            else:
                unused, refs, compiled_size, variables, script_type, flags = struct.unpack(
                    "<IIIIHH", payload
                )
                current["header"] = {
                    "unused": unused,
                    "referenceCount": refs,
                    "compiledSize": compiled_size,
                    "variableCount": variables,
                    "scriptType": script_type,
                    "flags": flags,
                }
            continue

        if name in SCRIPT_SUBRECORDS - {b"SCHR"}:
            if current is None:
                current = {
                    "context": _segment_context(
                        raw.rtype,
                        info_end=info_end,
                        quest_stage=quest_stage,
                        quest_entry=quest_entry,
                        terminal_item=terminal_item,
                        package_event=package_event,
                    ),
                    "header": None,
                    "compiled": [],
                    "sources": [],
                    "references": [],
                    "referenceVariables": [],
                    "locals": [],
                    "unmaterializedReferenceSlots": 0,
                }
            if name == b"SCDA":
                try:
                    frames = _parse_compiled_frames(payload)
                except InventoryError as error:
                    record_anomaly("scda-framing", str(error))
                    frames = []
                current["compiled"].append(
                    {
                        "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "frames": frames,
                    }
                )
            elif name == b"SCTX":
                try:
                    text, terminated = _decode_sctx(payload)
                    tokens = _tokenize(text)
                    commands = _source_command_candidates(text)
                except InventoryError as error:
                    record_anomaly("sctx-structure", str(error))
                    text = ""
                    terminated = payload.endswith(b"\0")
                    tokens = []
                    commands = []
                token_counts = Counter((token.kind, token.normalized) for token in tokens)
                fingerprint = hashlib.sha256()
                for token in tokens:
                    fingerprint.update(token.kind.encode("ascii"))
                    fingerprint.update(b"\0")
                    fingerprint.update(token.normalized.encode("utf-8"))
                    fingerprint.update(b"\n")
                current["sources"].append(
                    {
                        "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "nulTerminated": terminated,
                        "tokenCount": len(tokens),
                        "tokenFingerprintSha256": fingerprint.hexdigest(),
                        "tokenCounts": [
                            {"kind": kind, "token": token, "occurrences": count}
                            for (kind, token), count in sorted(token_counts.items())
                        ],
                        "commandCandidates": [
                            {"token": token, "role": role} for token, role in commands
                        ],
                    }
                )
            elif name == b"SCRO":
                if len(payload) != 4:
                    record_anomaly("scro-size", f"SCRO has {len(payload)} bytes; expected 4")
                else:
                    current["references"].append(
                        {"targetRaw": _hex32(_u32(payload, 0)), "_targetRaw": _u32(payload, 0)}
                    )
            elif name == b"SCRV":
                if len(payload) != 4:
                    record_anomaly("scrv-size", f"SCRV has {len(payload)} bytes; expected 4")
                else:
                    current["referenceVariables"].append(_u32(payload, 0))
            elif name == b"SLSD":
                if len(payload) != 24:
                    record_anomaly("slsd-size", f"SLSD has {len(payload)} bytes; expected 24")
                else:
                    values = struct.unpack("<IIIIII", payload)
                    current["locals"].append(
                        {"index": values[0], "type": values[4], "name": None}
                    )
            elif name == b"SCVR":
                if not current["locals"]:
                    record_anomaly("scvr-without-slsd", "SCVR appears without a preceding SLSD")
                else:
                    current["locals"][-1]["name"] = payload.split(b"\0", 1)[0].decode("cp1252")
            continue

    finish_segment()
    return {
        "formId": fact.form_id,
        "rawFormId": raw.raw_form_id,
        "recordType": raw.rtype,
        "sourceIndex": source.load_index,
        "sourcePlugin": source.name,
        "recordOffset": raw.offset,
        "flags": raw.flags,
        "editorId": editor_id,
        "selectedFamily": is_selected,
        "attachments": attachments,
        "conditions": conditions,
        "segments": segments,
    }


def _select_official_sources(
    paths: Sequence[Path], *, require_complete_scope: bool
) -> tuple[list[corpus.PluginSource], list[str]]:
    inspected = corpus.inspect_plugins(paths)
    official_paths = [source.path for source in inspected if source.role == "official"]
    excluded = [source.name for source in inspected if source.role != "official"]
    if not official_paths:
        raise InventoryError("No official Fallout: New Vegas plugins were supplied")

    # Re-index the official layer without FNVR or any other compatibility mod.
    sources = corpus.inspect_plugins(official_paths)
    actual_names = [source.name for source in sources]
    if require_complete_scope:
        if actual_names != list(corpus.OFFICIAL_NAMES):
            raise InventoryError(
                "Official plugin order/set does not match the frozen scope: "
                + ", ".join(actual_names)
            )
        for source in sources:
            expected_bytes, expected_sha = EXPECTED_OFFICIAL[source.name]
            if source.size != expected_bytes or source.sha256 != expected_sha:
                raise InventoryError(
                    f"Frozen source mismatch for {source.name}: "
                    f"bytes={source.size} sha256={source.sha256}"
                )
    return sources, excluded


def _attachment_category(record_type: str) -> str:
    if record_type == "QUST":
        return "quest"
    if record_type in ("DIAL", "INFO"):
        return "dialogue"
    if record_type == "TERM":
        return "terminal"
    if record_type == "PACK":
        return "package"
    if record_type in EFFECT_RECORD_TYPES:
        return "effect"
    return "object"


def _resolve_reference(
    *,
    raw: int,
    source: corpus.PluginSource,
    by_name: Mapping[str, corpus.PluginSource],
    winners: Mapping[int, corpus.RecordFacts],
    owner_id: str,
    artifact_id: str,
    kind: str,
    unresolved: list[dict],
    expected_type: str | None = None,
) -> dict:
    result = {"raw": _hex32(raw), "resolved": None, "targetRecordType": None}
    if raw == 0:
        unresolved.append(
            {
                "owner": owner_id,
                "artifact": artifact_id,
                "kind": kind,
                "raw": _hex32(raw),
                "resolved": None,
                "reason": "zero-form-id",
            }
        )
        return result
    try:
        resolved = _resolve_authored_form_id(raw, source, by_name)
    except InventoryError as error:
        unresolved.append(
            {
                "owner": owner_id,
                "artifact": artifact_id,
                "kind": kind,
                "raw": _hex32(raw),
                "resolved": None,
                "reason": "invalid-local-master-index",
                "detail": str(error),
            }
        )
        return result
    assert resolved is not None
    result["resolved"] = _hex32(resolved)
    reserved_name = ENGINE_RESERVED_FORM_IDS.get(resolved)
    if reserved_name is not None:
        result["targetRecordType"] = "ENGINE_RESERVED"
        result["engineReserved"] = reserved_name
        result["targetDeleted"] = False
        return result
    target = winners.get(resolved)
    if target is None:
        unresolved.append(
            {
                "owner": owner_id,
                "artifact": artifact_id,
                "kind": kind,
                "raw": _hex32(raw),
                "resolved": _hex32(resolved),
                "reason": "missing-winning-record",
            }
        )
        return result
    result["targetRecordType"] = target.rtype
    result["targetDeleted"] = target.deleted
    if target.deleted:
        unresolved.append(
            {
                "owner": owner_id,
                "artifact": artifact_id,
                "kind": kind,
                "raw": _hex32(raw),
                "resolved": _hex32(resolved),
                "reason": "target-deleted",
            }
        )
    elif expected_type is not None and target.rtype != expected_type:
        unresolved.append(
            {
                "owner": owner_id,
                "artifact": artifact_id,
                "kind": kind,
                "raw": _hex32(raw),
                "resolved": _hex32(resolved),
                "reason": f"target-is-{target.rtype}-not-{expected_type}",
            }
        )
    return result


def _new_bite(kind: str, key: str) -> dict:
    return {
        "id": f"{kind}:{key}",
        "kind": kind,
        "key": key,
        "authoredOccurrences": 0,
        "_records": set(),
        "disposition": "uncovered",
        "implementationArtifacts": [],
        "evidence": [],
        "notes": "",
    }


def _add_bite(
    bites: dict[tuple[str, str], dict],
    kind: str,
    key: str,
    owner_id: str,
    occurrences: int = 1,
) -> None:
    bite = bites.setdefault((kind, key), _new_bite(kind, key))
    bite["authoredOccurrences"] += occurrences
    bite["_records"].add(owner_id)


def _clean_bites(bites: Mapping[tuple[str, str], dict]) -> list[dict]:
    result: list[dict] = []
    for key in sorted(bites):
        raw = bites[key]
        result.append(
            {
                name: value
                for name, value in raw.items()
                if name != "_records"
            }
            | {"affectedRecords": len(raw["_records"])}
        )
    return result


def _scan_official_layer(
    sources: Sequence[corpus.PluginSource],
) -> tuple[
    dict[int, corpus.RecordFacts],
    dict[int, dict | None],
    Counter[str],
    list[dict],
    list[dict],
]:
    by_name = {source.name.casefold(): source for source in sources}
    winners: dict[int, corpus.RecordFacts] = {}
    candidates: dict[int, dict | None] = {}
    physical_types: Counter[str] = Counter()
    anomalies: list[dict] = []
    unresolved_records: list[dict] = []

    for source in sources:
        raw_iterator = _iter_raw_plugin_records(source)
        fact_iterator = corpus.iter_plugin_records(source, by_name)
        raw_count = 0
        fact_count = 0
        while True:
            try:
                raw = next(raw_iterator)
                raw_done = False
                raw_count += 1
            except StopIteration:
                raw = None
                raw_done = True
            try:
                fact = next(fact_iterator)
                fact_done = False
                fact_count += 1
            except StopIteration:
                fact = None
                fact_done = True
            if raw_done and fact_done:
                break
            if raw_done != fact_done:
                raise InventoryError(
                    f"Raw/corpus record-count mismatch in {source.name}: "
                    f"raw={raw_count} corpus={fact_count}"
                )
            assert raw is not None and fact is not None
            if raw.rtype != fact.rtype or raw.flags != fact.flags:
                raise InventoryError(
                    f"Raw/corpus identity mismatch in {source.name} at "
                    f"0x{raw.offset:x}: raw={raw.rtype}/{raw.flags:#x} "
                    f"corpus={fact.rtype}/{fact.flags:#x}"
                )

            physical_types[raw.rtype] += 1
            candidate = _parse_record_candidate(source, fact, raw, anomalies)
            if fact.form_id is None:
                unresolved_records.append(
                    {
                        "plugin": source.name,
                        "recordType": raw.rtype,
                        "rawFormId": _hex32(raw.raw_form_id),
                        "recordOffset": f"0x{raw.offset:08x}",
                        "reason": "frozen-corpus-unresolvable-record-form-id",
                        "allowedByCorpusScanner": True,
                    }
                )
                continue
            winners[fact.form_id] = fact
            candidates[fact.form_id] = candidate

    return winners, candidates, physical_types, anomalies, unresolved_records


def _materialize_inventory(
    sources: Sequence[corpus.PluginSource],
    winners: Mapping[int, corpus.RecordFacts],
    candidates: Mapping[int, dict | None],
    unresolved_records: Sequence[dict],
) -> dict:
    by_name = {source.name.casefold(): source for source in sources}
    by_index = {source.load_index: source for source in sources}
    records: list[dict] = []
    attachments: list[dict] = []
    script_segments: list[dict] = []
    compiled_blobs: list[dict] = []
    source_blobs: list[dict] = []
    conditions: list[dict] = []
    unresolved: list[dict] = list(unresolved_records)
    source_token_totals: Counter[tuple[str, str]] = Counter()
    source_token_blobs: defaultdict[tuple[str, str], set[str]] = defaultdict(set)
    bites: dict[tuple[str, str], dict] = {}

    for form_id in sorted(winners):
        fact = winners[form_id]
        if fact.deleted:
            continue
        candidate = candidates.get(form_id)
        is_selected = fact.rtype in SELECTED_RECORD_TYPES
        if not is_selected and candidate is None:
            continue
        owner_id = _record_id(form_id)
        source = by_index[fact.source_index]
        if candidate is None:
            # A malformed selected record remains in the family denominator;
            # its parse anomaly prevents a complete report.
            records.append(
                {
                    "id": owner_id,
                    "formId": _hex32(form_id),
                    "recordType": fact.rtype,
                    "sourcePlugin": source.name,
                    "editorId": "",
                    "selectedFamily": is_selected,
                    "scriptAttachmentCount": 0,
                    "conditionCount": 0,
                    "scriptSegmentCount": 0,
                    "parseFailed": True,
                }
            )
            continue

        record_attachment_ids: list[str] = []
        for ordinal, raw_attachment in enumerate(candidate["attachments"]):
            artifact_id = _artifact_id(form_id, "scri", ordinal)
            resolved = _resolve_reference(
                raw=raw_attachment["_targetRaw"],
                source=source,
                by_name=by_name,
                winners=winners,
                owner_id=owner_id,
                artifact_id=artifact_id,
                kind="SCRI",
                unresolved=unresolved,
                expected_type="SCPT",
            )
            row = {
                "id": artifact_id,
                "owner": owner_id,
                "ownerRecordType": fact.rtype,
                "category": _attachment_category(fact.rtype),
                "sourcePlugin": source.name,
                "target": resolved,
            }
            attachments.append(row)
            record_attachment_ids.append(artifact_id)
            _add_bite(bites, "script-attachment-owner", fact.rtype, owner_id)

        record_condition_ids: list[str] = []
        for ordinal, raw_condition in enumerate(candidate["conditions"]):
            artifact_id = _artifact_id(form_id, "condition", ordinal)
            condition = {
                key: value for key, value in raw_condition.items() if not key.startswith("_")
            }
            condition.update(
                {
                    "id": artifact_id,
                    "owner": owner_id,
                    "ownerRecordType": fact.rtype,
                    "sourcePlugin": source.name,
                }
            )
            reference_raw = raw_condition["_referenceRaw"]
            comparison_raw = raw_condition["_comparisonRaw"]
            if reference_raw:
                condition["reference"] = _resolve_reference(
                    raw=reference_raw,
                    source=source,
                    by_name=by_name,
                    winners=winners,
                    owner_id=owner_id,
                    artifact_id=artifact_id,
                    kind="CTDA.reference",
                    unresolved=unresolved,
                )
            else:
                condition["reference"] = None
                if condition["runOn"] == 2:
                    unresolved.append(
                        {
                            "owner": owner_id,
                            "artifact": artifact_id,
                            "kind": "CTDA.reference",
                            "raw": _hex32(0),
                            "resolved": None,
                            "reason": "run-on-reference-with-zero-reference",
                        }
                    )
            if comparison_raw:
                condition["comparisonGlobal"] = _resolve_reference(
                    raw=comparison_raw,
                    source=source,
                    by_name=by_name,
                    winners=winners,
                    owner_id=owner_id,
                    artifact_id=artifact_id,
                    kind="CTDA.comparison-global",
                    unresolved=unresolved,
                    expected_type="GLOB",
                )
            else:
                condition["comparisonGlobal"] = None
            conditions.append(condition)
            record_condition_ids.append(artifact_id)
            _add_bite(bites, "condition-function", str(condition["functionId"]), owner_id)
            _add_bite(bites, "condition-run-on", condition["runOnName"], owner_id)

        record_segment_ids: list[str] = []
        for ordinal, raw_segment in enumerate(candidate["segments"]):
            segment_id = _artifact_id(form_id, "script", ordinal)
            record_segment_ids.append(segment_id)
            _add_bite(bites, "script-context", raw_segment["context"], owner_id)
            segment_references: list[dict] = []
            for ref_ordinal, raw_reference in enumerate(raw_segment["references"]):
                reference_id = f"{segment_id}:scro:{ref_ordinal}"
                segment_references.append(
                    {
                        "id": reference_id,
                        **_resolve_reference(
                            raw=raw_reference["_targetRaw"],
                            source=source,
                            by_name=by_name,
                            winners=winners,
                            owner_id=owner_id,
                            artifact_id=reference_id,
                            kind="SCRO",
                            unresolved=unresolved,
                        ),
                    }
                )
            for slot in range(raw_segment["unmaterializedReferenceSlots"]):
                unresolved.append(
                    {
                        "owner": owner_id,
                        "artifact": f"{segment_id}:reference-slot:{slot}",
                        "kind": "SCHR.reference-slot",
                        "raw": None,
                        "resolved": None,
                        "reason": "source-only-unmaterialized-reference-slot",
                    }
                )

            compiled_ids: list[str] = []
            for blob_ordinal, raw_blob in enumerate(raw_segment["compiled"]):
                blob_id = f"{segment_id}:scda:{blob_ordinal}"
                compiled_ids.append(blob_id)
                frames = raw_blob["frames"]
                compiled_blobs.append(
                    {
                        "id": blob_id,
                        "owner": owner_id,
                        "segment": segment_id,
                        "bytes": raw_blob["bytes"],
                        "sha256": raw_blob["sha256"],
                        "frameCount": len(frames),
                        "frames": frames,
                    }
                )
                for frame in frames:
                    _add_bite(bites, "compiled-opcode", frame["opcode"], owner_id)
                    if "eventOpcode" in frame:
                        _add_bite(bites, "compiled-event", frame["eventOpcode"], owner_id)

            source_ids: list[str] = []
            for blob_ordinal, raw_blob in enumerate(raw_segment["sources"]):
                blob_id = f"{segment_id}:sctx:{blob_ordinal}"
                source_ids.append(blob_id)
                source_blobs.append(
                    {
                        "id": blob_id,
                        "owner": owner_id,
                        "segment": segment_id,
                        **raw_blob,
                    }
                )
                for token in raw_blob["tokenCounts"]:
                    token_key = (token["kind"], token["token"])
                    source_token_totals[token_key] += token["occurrences"]
                    source_token_blobs[token_key].add(blob_id)
                for command in raw_blob["commandCandidates"]:
                    _add_bite(bites, "source-command", command["token"], owner_id)

            script_segments.append(
                {
                    "id": segment_id,
                    "owner": owner_id,
                    "ownerRecordType": fact.rtype,
                    "sourcePlugin": source.name,
                    "context": raw_segment["context"],
                    "header": raw_segment["header"],
                    "compiledBlobs": compiled_ids,
                    "sourceBlobs": source_ids,
                    "references": segment_references,
                    "referenceVariables": raw_segment["referenceVariables"],
                    "unmaterializedReferenceSlots": raw_segment[
                        "unmaterializedReferenceSlots"
                    ],
                    "locals": raw_segment["locals"],
                }
            )

        records.append(
            {
                "id": owner_id,
                "formId": _hex32(form_id),
                "recordType": fact.rtype,
                "sourcePlugin": source.name,
                "editorId": candidate["editorId"],
                "selectedFamily": is_selected,
                "scriptAttachmentCount": len(record_attachment_ids),
                "conditionCount": len(record_condition_ids),
                "scriptSegmentCount": len(record_segment_ids),
                "scriptAttachments": record_attachment_ids,
                "conditions": record_condition_ids,
                "scriptSegments": record_segment_ids,
                "parseFailed": False,
            }
        )

    source_tokens = [
        {
            "kind": kind,
            "token": token,
            "occurrences": source_token_totals[(kind, token)],
            "sourceBlobs": len(source_token_blobs[(kind, token)]),
        }
        for kind, token in sorted(source_token_totals)
    ]
    return {
        "records": records,
        "scriptAttachments": attachments,
        "scriptSegments": script_segments,
        "compiledBlobs": compiled_blobs,
        "sourceBlobs": source_blobs,
        "sourceTokens": source_tokens,
        "conditions": conditions,
        "unresolved": sorted(
            unresolved,
            key=lambda item: (
                item.get("plugin", ""),
                item.get("owner", ""),
                item.get("artifact", ""),
                item.get("kind", ""),
                item.get("reason", ""),
            ),
        ),
        "workloadBites": _clean_bites(bites),
    }


def _record_family_counts(
    physical_types: Mapping[str, int], winners: Mapping[int, corpus.RecordFacts]
) -> dict:
    winning = Counter(fact.rtype for fact in winners.values())
    live = Counter(fact.rtype for fact in winners.values() if not fact.deleted)
    return {
        rtype: {
            "physical": physical_types.get(rtype, 0),
            "winningIncludingDeleted": winning.get(rtype, 0),
            "winningLive": live.get(rtype, 0),
        }
        for rtype in sorted(SELECTED_RECORD_TYPES)
    }


def _summary(
    materialized: Mapping,
    winners: Mapping[int, corpus.RecordFacts],
    physical_types: Mapping[str, int],
    anomalies: Sequence[dict],
) -> dict:
    compiled = materialized["compiledBlobs"]
    sources = materialized["sourceBlobs"]
    opcode_frames = sum(item["frameCount"] for item in compiled)
    command_bites = [
        item for item in materialized["workloadBites"] if item["kind"] == "source-command"
    ]
    opcode_bites = [
        item for item in materialized["workloadBites"] if item["kind"] == "compiled-opcode"
    ]
    condition_function_bites = [
        item
        for item in materialized["workloadBites"]
        if item["kind"] == "condition-function"
    ]
    return {
        "physicalNonTes4Records": sum(physical_types.values()),
        "winningRecordsIncludingDeleted": len(winners),
        "winningDeletedRecords": sum(fact.deleted for fact in winners.values()),
        "winningLiveRecords": sum(not fact.deleted for fact in winners.values()),
        "inventoryRecordRows": len(materialized["records"]),
        "scriptAttachments": len(materialized["scriptAttachments"]),
        "scriptSegments": len(materialized["scriptSegments"]),
        "compiledScdaBlobs": len(compiled),
        "compiledScdaBytes": sum(item["bytes"] for item in compiled),
        "compiledOpcodeFrames": opcode_frames,
        "distinctCompiledOpcodes": len(opcode_bites),
        "sourceSctxBlobs": len(sources),
        "sourceSctxBytes": sum(item["bytes"] for item in sources),
        "sourceTokens": sum(item["tokenCount"] for item in sources),
        "distinctSourceTokens": len(materialized["sourceTokens"]),
        "distinctSourceCommandCandidates": len(command_bites),
        "conditions": len(materialized["conditions"]),
        "distinctConditionFunctions": len(condition_function_bites),
        "unresolvedRows": len(materialized["unresolved"]),
        "parseAnomalyRows": len(anomalies),
        "workloadBites": len(materialized["workloadBites"]),
        "disposedWorkloadBites": sum(
            item["disposition"] != "uncovered" for item in materialized["workloadBites"]
        ),
    }


def build_inventory(
    paths: Sequence[Path], *, require_complete_scope: bool = True
) -> dict:
    sources, excluded = _select_official_sources(
        paths, require_complete_scope=require_complete_scope
    )
    winners, candidates, physical_types, anomalies, unresolved_records = _scan_official_layer(
        sources
    )
    materialized = _materialize_inventory(sources, winners, candidates, unresolved_records)
    anomalies = sorted(
        anomalies,
        key=lambda item: (
            item["plugin"],
            item["recordOffset"],
            item["code"],
            item["detail"],
        ),
    )
    complete = not anomalies
    report = {
        "schema": SCHEMA,
        "scopeId": SCOPE_ID,
        "status": "inventory-complete" if complete else "incomplete-parse-anomalies",
        "inventoryComplete": complete,
        "semantics": {
            "retailLayer": "The ten official English Ultimate Edition masters only; FNVR and every extra plugin are excluded before FormID resolution.",
            "winning": "Last official override per master-resolved FormID; detailed artifacts come from winning live records only.",
            "physical": "Every non-TES4 record is still scanned and cross-checked against export_fnv_parity_corpus.py.",
            "compiledOpcodes": "SCDA is decoded as xNVSE ScriptIterator line framing: opcode+length, or 0x001c+reference+opcode+length.",
            "sourceCommands": "Conservative lexical candidates; they are not treated as semantic command resolution.",
            "conditions": "CTDA/CTDT 20/24/28/36-byte layouts only. Function IDs and RunOn values are inventories, not implementation claims.",
            "failClosed": "Any unknown subrecord/script/condition structure creates a parseAnomaly row, inventoryComplete=false, and a nonzero default CLI exit.",
            "paths": "No local filesystem path is serialized; output identity depends only on official plugin bytes and generator semantics.",
        },
        "dispositionSchema": {
            "allowed": list(DISPOSITIONS),
            "default": "uncovered",
            "meaning": "Every workload bite stays uncovered until a reviewed overlay assigns exactly one implementation disposition and evidence.",
        },
        "plugins": [
            {
                "order": source.load_index,
                "name": source.name,
                "bytes": source.size,
                "sha256": source.sha256,
                "masters": list(source.masters),
            }
            for source in sources
        ],
        "excludedPluginNames": excluded,
        "recordFamilies": _record_family_counts(physical_types, winners),
        "summary": _summary(materialized, winners, physical_types, anomalies),
        **materialized,
        "parseAnomalies": anomalies,
    }
    report["canonicalSha256"] = _canonical_digest(report)
    return report


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=repo_root / "profiles" / "fallout_new_vegas" / "openmw.cfg",
        help="OpenMW config used only to locate plugin files",
    )
    parser.add_argument(
        "--plugin",
        action="append",
        type=Path,
        default=[],
        help="Explicit plugin path in load order; repeat to bypass --config",
    )
    parser.add_argument("--output", type=Path, help="Write JSON here instead of stdout")
    parser.add_argument("--compact", action="store_true", help="Emit single-line JSON")
    parser.add_argument(
        "--allow-partial-scope",
        action="store_true",
        help="Diagnostic/test mode: do not require all ten pinned official hashes",
    )
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Return zero even when parse anomalies mark the report incomplete",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        paths = (
            [path.resolve() for path in args.plugin]
            if args.plugin
            else corpus.plugin_paths_from_config(args.config)
        )
        report = build_inventory(
            paths, require_complete_scope=not args.allow_partial_scope
        )
    except (InventoryError, corpus.CorpusError, OSError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    text = json.dumps(
        report,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":") if args.compact else None,
        indent=None if args.compact else 2,
    ) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    if not report["inventoryComplete"] and not args.allow_incomplete:
        print(
            f"error: inventory has {len(report['parseAnomalies'])} parse anomaly rows",
            file=sys.stderr,
        )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
