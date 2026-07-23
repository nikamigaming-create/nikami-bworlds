#!/usr/bin/env python3
"""Inventory authored Fallout 3/New Vegas QUST bytecode without executing it."""

import argparse
import collections
import json
import struct
import zlib
from pathlib import Path

from export_esm4_catalog import REC_COMPRESSED, ESM4Catalog, subrecords, u16, u32, zstr


def iter_records(data, header_size, start, end):
    offset = start
    while offset + header_size <= end:
        kind = data[offset : offset + 4]
        if kind == b"GRUP":
            size = u32(data, offset + 4)
            if size < header_size or offset + size > end:
                return
            yield from iter_records(data, header_size, offset + header_size, offset + size)
            offset += size
            continue
        size = u32(data, offset + 4)
        payload_start = offset + header_size
        payload_end = payload_start + size
        if payload_end > end:
            return
        yield kind, u32(data, offset + 8), u32(data, offset + 12), data[payload_start:payload_end]
        offset = payload_end


def decode_scda(data):
    decoded = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < 4:
            return decoded, f"truncated header at {offset}"
        outer = u16(data, offset)
        if outer == 0x001C:
            if len(data) - offset < 8:
                return decoded, f"truncated reference header at {offset}"
            opcode = u16(data, offset + 4)
            arg_size = u16(data, offset + 6)
            header_size = 8
            reference = u16(data, offset + 2)
        else:
            opcode = outer
            arg_size = u16(data, offset + 2)
            header_size = 4
            reference = None
        next_offset = offset + header_size + arg_size
        if next_offset > len(data):
            return decoded, f"argument overrun at {offset}"
        decoded.append({"offset": offset, "opcode": opcode, "reference": reference, "argumentBytes": arg_size})
        offset = next_offset
    return decoded, None


def parse_quest(form_id, payload):
    editor_id = ""
    stage = None
    entry = None
    entry_index = -1
    scripts = []
    last_script = None
    for name, raw in subrecords(payload):
        if name == "EDID":
            editor_id = zstr(raw)
        elif name == "INDX" and len(raw) == 2:
            stage = struct.unpack_from("<h", raw)[0]
            entry = None
            entry_index = -1
            last_script = None
        elif name == "QSDT":
            entry_index += 1
            entry = entry_index
            last_script = None
        elif name == "QOBJ":
            stage = None
            entry = None
            last_script = None
        elif name == "SCDA":
            instructions, error = decode_scda(raw)
            last_script = {
                "stage": stage,
                "entry": entry,
                "compiledBytes": len(raw),
                "instructions": instructions,
                "decodeError": error,
                "source": "",
            }
            scripts.append(last_script)
        elif name == "SCTX" and last_script is not None:
            last_script["source"] = raw.rstrip(b"\0").decode("cp1252", errors="replace")
    return {"formId": f"0x{form_id:08x}", "editorId": editor_id, "scripts": scripts}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("plugin", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()

    catalog = ESM4Catalog(args.plugin)
    data = catalog.data
    quests = []
    opcode_counts = collections.Counter()
    opcode_quests = collections.defaultdict(set)
    malformed = []
    for kind, flags, form_id, payload in iter_records(data, catalog.header_size, 0, len(data)):
        if kind != b"QUST":
            continue
        if flags & REC_COMPRESSED:
            payload = zlib.decompress(payload[4:])
        quest = parse_quest(form_id, payload)
        for script in quest["scripts"]:
            if script["decodeError"]:
                malformed.append({"quest": quest["editorId"], "stage": script["stage"], "error": script["decodeError"]})
            for instruction in script["instructions"]:
                opcode = instruction["opcode"]
                opcode_counts[opcode] += 1
                opcode_quests[opcode].add(quest["editorId"])
        quests.append(quest)

    result = {
        "plugin": str(args.plugin.resolve()),
        "questCount": len(quests),
        "scriptCount": sum(len(q["scripts"]) for q in quests),
        "instructionCount": sum(opcode_counts.values()),
        "malformed": malformed,
        "opcodes": [
            {
                "opcode": f"0x{opcode:04x}",
                "count": count,
                "questCount": len(opcode_quests[opcode]),
                "quests": sorted(opcode_quests[opcode]),
            }
            for opcode, count in opcode_counts.most_common()
        ],
        "quests": quests,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(
        f"quests={result['questCount']} scripts={result['scriptCount']} "
        f"instructions={result['instructionCount']} malformed={len(malformed)}"
    )
    for row in result["opcodes"]:
        print(f"{row['opcode']} count={row['count']} quests={row['questCount']}")


if __name__ == "__main__":
    main()
