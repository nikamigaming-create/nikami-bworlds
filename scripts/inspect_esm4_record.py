#!/usr/bin/env python3
"""Print exact TES4-family record subrecords without launching a game runtime."""

import argparse
import json
import struct
import zlib
from pathlib import Path

from export_esm4_catalog import REC_COMPRESSED, subrecords, u32, zstr


def record_payloads(data, header_size, wanted, start=0, end=None):
    if end is None:
        end = len(data)
    offset = start
    while offset + header_size <= end:
        kind = data[offset : offset + 4]
        if kind == b"GRUP":
            group_size = u32(data, offset + 4)
            if group_size < header_size or offset + group_size > end:
                return
            yield from record_payloads(data, header_size, wanted, offset + header_size, offset + group_size)
            offset += group_size
            continue

        size = u32(data, offset + 4)
        flags = u32(data, offset + 8)
        form_id = u32(data, offset + 12)
        payload_start = offset + header_size
        payload_end = payload_start + size
        if payload_end > end:
            return
        if form_id in wanted:
            payload = data[payload_start:payload_end]
            if flags & REC_COMPRESSED and len(payload) >= 4:
                payload = zlib.decompress(payload[4:])
            yield kind.decode("ascii", errors="replace"), form_id, flags, payload
        offset = payload_end


def describe_subrecord(name, raw):
    item = {"name": name, "size": len(raw), "hex": raw[:64].hex()}
    if raw and raw[-1:] == b"\0":
        text = zstr(raw)
        if text and all(character.isprintable() for character in text):
            item["text"] = text
    if len(raw) == 4:
        item["u32"] = u32(raw, 0)
        item["formId"] = f"0x{u32(raw, 0):x}"
        item["float"] = struct.unpack_from("<f", raw, 0)[0]
    return item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esm", required=True)
    parser.add_argument("--id", action="append", required=True, dest="record_ids")
    parser.add_argument("--subrecord", action="append", default=[], dest="subrecord_names")
    args = parser.parse_args()

    path = Path(args.esm)
    data = path.read_bytes()
    if data[:4] != b"TES4":
        raise SystemExit(f"Not a TES4-family plugin: {path}")
    header_size = 20 if data[20:24] in (b"HEDR", b"OFST", b"CNAM", b"SNAM", b"MAST", b"DATA") else 24
    wanted = {int(value, 0) for value in args.record_ids}
    wanted_subrecords = {value.upper() for value in args.subrecord_names}
    records = []
    for record_type, form_id, flags, payload in record_payloads(data, header_size, wanted):
        records.append(
            {
                "type": record_type,
                "id": f"0x{form_id:x}",
                "flags": f"0x{flags:08x}",
                "subrecords": [
                    describe_subrecord(name, raw)
                    for name, raw in subrecords(payload)
                    if not wanted_subrecords or name in wanted_subrecords
                ],
            }
        )
    print(json.dumps({"source": str(path), "records": records}, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
