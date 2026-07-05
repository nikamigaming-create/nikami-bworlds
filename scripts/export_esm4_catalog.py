#!/usr/bin/env python3
import argparse
import json
import math
import struct
import zlib
from pathlib import Path

REC_COMPRESSED = 0x00040000
REC_LOCALIZED = 0x00000080
CELL_INTERIOR = 0x0001


def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def i32(data, offset):
    return struct.unpack_from("<i", data, offset)[0]


def f32(data, offset):
    return struct.unpack_from("<f", data, offset)[0]


def zstr(raw):
    raw = raw.split(b"\0", 1)[0]
    return raw.decode("cp1252", errors="replace")


def form(raw_form, mod_index):
    if raw_form == 0:
        return None
    return raw_form | (mod_index << 24)


def form_hex(value):
    if value is None:
        return None
    return f"0x{value:x}"


def openmw_form_id(value):
    if value is None:
        return None
    return f"FormId:0x{value:x}"


def subrecords(payload):
    offset = 0
    extended_size = None
    while offset + 6 <= len(payload):
        name = payload[offset : offset + 4].decode("ascii", errors="replace")
        size = u16(payload, offset + 4)
        offset += 6
        if name == "XXXX" and size >= 4 and offset + size <= len(payload):
            extended_size = u32(payload, offset)
            offset += size
            continue
        actual_size = extended_size if extended_size is not None else size
        extended_size = None
        if actual_size < 0 or offset + actual_size > len(payload):
            break
        yield name, payload[offset : offset + actual_size]
        offset += actual_size


class ESM4Catalog:
    def __init__(self, path, mod_index=1, terms=None):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.mod_index = mod_index
        self.terms = [term.lower() for term in (terms or []) if term]
        self.header_size = self.detect_header_size()
        self.localized = False
        self.records = {}
        self.worlds = {}
        self.cells = {}
        self.placements = []

    def detect_header_size(self):
        if self.data[:4] != b"TES4":
            raise ValueError(f"{self.path} is not an ESM4/TES4-family plugin")
        size = u32(self.data, 4)
        if self.data[20:24] in (b"HEDR", b"OFST", b"CNAM", b"SNAM", b"MAST", b"DATA"):
            return 20
        if self.data[24:28] in (b"HEDR", b"OFST", b"CNAM", b"SNAM", b"MAST", b"DATA"):
            return 24
        if 20 + size < len(self.data) and self.data[20 + size : 20 + size + 4] == b"GRUP":
            return 20
        return 24

    def parse(self):
        self.walk(0, len(self.data), None, None)

    def parse_payload(self, rtype, payload, flags):
        fields = {}
        for name, raw in subrecords(payload):
            if name == "EDID":
                fields["editorId"] = zstr(raw)
            elif name == "FULL":
                if self.localized and len(raw) == 4:
                    fields["fullNameStringId"] = u32(raw, 0)
                else:
                    fields["fullName"] = zstr(raw)
            elif rtype == "CELL" and name == "DATA":
                if len(raw) == 1:
                    fields["cellFlags"] = raw[0]
                elif len(raw) >= 2:
                    fields["cellFlags"] = u16(raw, 0)
            elif rtype == "CELL" and name == "XCLC" and len(raw) >= 8:
                fields["x"] = i32(raw, 0)
                fields["y"] = i32(raw, 4)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "NAME" and len(raw) >= 4:
                fields["base"] = form(u32(raw, 0), self.mod_index)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "DATA" and len(raw) >= 24:
                fields["pos"] = [f32(raw, 0), f32(raw, 4), f32(raw, 8)]
                fields["rot"] = [f32(raw, 12), f32(raw, 16), f32(raw, 20)]
            elif rtype == "WRLD" and name == "WCTR" and len(raw) >= 4:
                fields["centerCell"] = [struct.unpack_from("<h", raw, 0)[0], struct.unpack_from("<h", raw, 2)[0]]
        return fields

    def record_matches_terms(self, item):
        text = " ".join(
            str(item.get(key, "")) for key in ("editorId", "fullName", "type", "id", "parentCell", "parentWorld")
        ).lower()
        return [term for term in self.terms if term in text]

    def walk(self, start, end, current_world, current_cell):
        offset = start
        while offset + self.header_size <= end:
            kind = self.data[offset : offset + 4]
            if kind == b"GRUP":
                group_size = u32(self.data, offset + 4)
                if group_size < self.header_size:
                    break
                label = self.data[offset + 8 : offset + 12]
                group_type = u32(self.data, offset + 12)
                child_world = current_world
                child_cell = current_cell
                if group_type == 1:
                    child_world = form(u32(label, 0), self.mod_index)
                elif group_type in (6, 8, 9, 10):
                    child_cell = form(u32(label, 0), self.mod_index)
                child_start = offset + self.header_size
                child_end = min(offset + group_size, end)
                self.walk(child_start, child_end, child_world, child_cell)
                offset += group_size
                continue

            try:
                rtype = kind.decode("ascii")
            except UnicodeDecodeError:
                break
            size = u32(self.data, offset + 4)
            if size < 0:
                break
            flags = u32(self.data, offset + 8)
            raw_form = u32(self.data, offset + 12)
            rec_form = form(raw_form, self.mod_index)
            data_start = offset + self.header_size
            data_end = data_start + size
            if data_end > end or data_end > len(self.data):
                break
            payload = self.data[data_start:data_end]
            if rtype == "TES4":
                self.localized = (flags & REC_LOCALIZED) != 0
            if flags & REC_COMPRESSED and len(payload) >= 4:
                try:
                    payload = zlib.decompress(payload[4:])
                except zlib.error:
                    payload = b""
            fields = self.parse_payload(rtype, payload, flags)

            if rec_form is not None:
                record = {
                    "id": form_hex(rec_form),
                    "openmwId": openmw_form_id(rec_form),
                    "type": rtype,
                }
                if "editorId" in fields:
                    record["editorId"] = fields["editorId"]
                if "fullName" in fields:
                    record["fullName"] = fields["fullName"]
                matches = self.record_matches_terms(record)
                if matches:
                    record["matches"] = matches
                self.records[rec_form] = record

            if rtype == "WRLD" and rec_form is not None:
                world = {
                    "id": form_hex(rec_form),
                    "openmwId": openmw_form_id(rec_form),
                    "editorId": fields.get("editorId", ""),
                    "fullName": fields.get("fullName", ""),
                    "centerCell": fields.get("centerCell"),
                }
                self.worlds[rec_form] = world
                current_world = rec_form

            elif rtype == "CELL" and rec_form is not None:
                cell_flags = fields.get("cellFlags", 0)
                is_exterior = (cell_flags & CELL_INTERIOR) == 0
                cell = {
                    "id": form_hex(rec_form),
                    "openmwId": openmw_form_id(rec_form),
                    "editorId": fields.get("editorId", ""),
                    "fullName": fields.get("fullName", ""),
                    "cellFlags": cell_flags,
                    "isExterior": is_exterior,
                    "parentWorld": form_hex(current_world) if is_exterior else None,
                    "openmwParentWorld": openmw_form_id(current_world) if is_exterior else None,
                    "x": fields.get("x", 0),
                    "y": fields.get("y", 0),
                    "matches": [],
                    "matchedRefs": [],
                    "matchedRefCount": 0,
                }
                cell["matches"] = self.record_matches_terms(cell)
                self.cells[rec_form] = cell
                current_cell = rec_form

            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and rec_form is not None and current_cell is not None:
                placement = {
                    "id": form_hex(rec_form),
                    "openmwId": openmw_form_id(rec_form),
                    "type": rtype,
                    "parentCell": form_hex(current_cell),
                    "openmwParentCell": openmw_form_id(current_cell),
                    "base": form_hex(fields.get("base")),
                    "openmwBase": openmw_form_id(fields.get("base")),
                    "pos": fields.get("pos"),
                    "rot": fields.get("rot"),
                    "editorId": fields.get("editorId", ""),
                }
                self.placements.append(placement)

            offset = data_end

    def build_output(self):
        term_records = []
        for record in self.records.values():
            if record.get("matches"):
                term_records.append(record)

        base_matches = {int(record["id"], 16): record for record in term_records}
        for placement in self.placements:
            base = placement.get("base")
            if not base:
                continue
            base_int = int(base, 16)
            if base_int not in base_matches:
                continue
            cell_int = int(placement["parentCell"], 16)
            cell = self.cells.get(cell_int)
            if cell is None:
                continue
            ref = {
                "ref": placement["id"],
                "openmwRef": placement["openmwId"],
                "type": placement["type"],
                "base": base,
                "openmwBase": placement["openmwBase"],
                "baseEditorId": base_matches[base_int].get("editorId", ""),
                "pos": placement.get("pos"),
                "rot": placement.get("rot"),
            }
            cell["matchedRefs"].append(ref)

        for cell in self.cells.values():
            cell["matchedRefCount"] = len(cell["matchedRefs"])
            cell["score"] = len(cell["matches"]) * 50 + cell["matchedRefCount"]
            if cell["isExterior"]:
                cell["score"] += 10
            if cell["matchedRefs"]:
                xs = [ref["pos"][0] for ref in cell["matchedRefs"] if ref.get("pos")]
                ys = [ref["pos"][1] for ref in cell["matchedRefs"] if ref.get("pos")]
                zs = [ref["pos"][2] for ref in cell["matchedRefs"] if ref.get("pos")]
                if xs and ys and zs:
                    cell["matchedRefCenter"] = [sum(xs) / len(xs), sum(ys) / len(ys), sum(zs) / len(zs)]
                    cell["matchedRefSpread"] = math.sqrt(
                        sum((x - cell["matchedRefCenter"][0]) ** 2 for x in xs) / len(xs)
                        + sum((y - cell["matchedRefCenter"][1]) ** 2 for y in ys) / len(ys)
                    )
            if len(cell["matchedRefs"]) > 20:
                cell["matchedRefs"] = cell["matchedRefs"][:20]

        cells = sorted(self.cells.values(), key=lambda c: (c["score"], c["matchedRefCount"]), reverse=True)
        top_cells = [cell for cell in cells if cell["score"] > 0][:200]
        worlds = sorted(self.worlds.values(), key=lambda w: w.get("editorId", ""))
        return {
            "schemaVersion": 1,
            "source": str(self.path),
            "modIndex": self.mod_index,
            "recordHeaderSize": self.header_size,
            "localized": self.localized,
            "terms": self.terms,
            "counts": {
                "records": len(self.records),
                "worlds": len(self.worlds),
                "cells": len(self.cells),
                "placements": len(self.placements),
                "termRecords": len(term_records),
            },
            "worlds": worlds,
            "termRecords": term_records[:1000],
            "topCells": top_cells,
        }


def main():
    parser = argparse.ArgumentParser(description="Export a narrow ESM4 cell/ref catalog for world-viewer starts.")
    parser.add_argument("--esm", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mod-index", type=int, default=1)
    parser.add_argument("--terms", nargs="*", default=[])
    args = parser.parse_args()

    catalog = ESM4Catalog(args.esm, mod_index=args.mod_index, terms=args.terms)
    catalog.parse()
    output = catalog.build_output()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(output, indent=2), encoding="ascii")
    print(json.dumps({"out": str(out), "counts": output["counts"], "topCells": output["topCells"][:10]}, indent=2))


if __name__ == "__main__":
    main()
