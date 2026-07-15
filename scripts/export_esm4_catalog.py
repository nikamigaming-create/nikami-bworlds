#!/usr/bin/env python3
import argparse
import hashlib
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


def form_from_raw(raw_form, mod_index):
    return form(u32(raw_form, 0), mod_index) if len(raw_form) >= 4 else None


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
    def __init__(self, path, mod_index=0, terms=None):
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
            elif rtype == "GMST" and name == "DATA" and len(raw) >= 4:
                setting_id = fields.get("editorId", "")
                setting_type = setting_id[:1]
                if setting_type == "f":
                    fields["settingValue"] = f32(raw, 0)
                elif setting_type == "i":
                    fields["settingValue"] = i32(raw, 0)
                elif setting_type == "b":
                    fields["settingValue"] = u32(raw, 0) != 0
                elif setting_type == "u":
                    fields["settingValue"] = u32(raw, 0)
                elif setting_type == "s":
                    fields["settingValue"] = zstr(raw)
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
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XSCL" and len(raw) >= 4:
                fields["scale"] = f32(raw, 0)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XESP" and len(raw) >= 8:
                fields["enableParent"] = form_from_raw(raw, self.mod_index)
                fields["enableParentFlags"] = u32(raw, 4)
            elif rtype in ("NPC_", "CREA") and name == "ACBS" and len(raw) >= 4:
                fields["actorFlags"] = u32(raw, 0)
                # TES4-family actor flags use bit 0 for female on the games we mine here.
                fields["femaleFlag"] = (fields["actorFlags"] & 1) != 0
            elif rtype == "NPC_" and name == "RNAM" and len(raw) >= 4:
                fields["race"] = form_from_raw(raw, self.mod_index)
            elif rtype == "NPC_" and name == "HNAM" and len(raw) >= 4:
                fields["hair"] = form_from_raw(raw, self.mod_index)
            elif rtype == "NPC_" and name == "ENAM" and len(raw) >= 4:
                fields["eyes"] = form_from_raw(raw, self.mod_index)
            elif rtype == "NPC_" and name == "PNAM" and len(raw) >= 4:
                fields.setdefault("headParts", []).append(form_from_raw(raw, self.mod_index))
            elif rtype == "NPC_" and name == "TPLT" and len(raw) >= 4:
                fields["baseTemplate"] = form_from_raw(raw, self.mod_index)
            elif rtype == "NPC_" and name == "EAMT" and len(raw) >= 2:
                fields["templateFlags"] = u16(raw, 0)
            elif rtype in ("NPC_", "CREA", "CONT") and name == "CNTO" and len(raw) >= 8:
                fields.setdefault("inventory", []).append(
                    {
                        "item": form_from_raw(raw, self.mod_index),
                        "count": i32(raw, 4),
                    }
                )
            elif rtype == "NPC_" and name == "DOFT" and len(raw) >= 4:
                fields["defaultOutfit"] = form_from_raw(raw, self.mod_index)
            elif rtype == "NPC_" and name == "SOFT" and len(raw) >= 4:
                fields["sleepOutfit"] = form_from_raw(raw, self.mod_index)
            elif rtype == "NPC_" and name == "LNAM" and len(raw) >= 4:
                fields["hairLength"] = f32(raw, 0)
            elif rtype == "NPC_" and name == "HCLR" and len(raw) >= 4:
                fields["hairColorRgba"] = list(raw[:4])
            elif rtype == "NPC_" and name in ("FGGS", "FGGA", "FGTS"):
                fields.setdefault("faceGenFingerprints", {})[name] = {
                    "bytes": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest(),
                }
            elif rtype in ("NPC_", "CREA", "ARMO", "CLOT", "WEAP") and name in ("MODL", "MOD2", "MOD3", "MOD4"):
                fields.setdefault("models", []).append(zstr(raw))
                fields.setdefault("modelSlots", []).append({"slot": name, "model": zstr(raw)})
            elif rtype in ("HAIR", "EYES", "HDPT") and name in ("MODL", "MOD2", "MOD3", "MOD4"):
                fields.setdefault("models", []).append(zstr(raw))
            elif rtype == "IDLE" and name == "MODL":
                fields["model"] = zstr(raw)
            elif rtype == "IDLE" and name == "DNAM":
                fields["collision"] = zstr(raw)
            elif rtype == "IDLE" and name == "ENAM":
                fields["event"] = zstr(raw)
            elif rtype == "IDLE" and name == "ANAM" and len(raw) >= 8:
                fields["parent"] = form_from_raw(raw, self.mod_index)
                fields["previous"] = form_from_raw(raw[4:], self.mod_index)
            elif rtype == "IDLE" and name in ("CTDA", "CTDT"):
                fields.setdefault("conditionData", []).append(
                    {
                        "subrecord": name,
                        "bytes": len(raw),
                        "hex": raw.hex(),
                    }
                )
            elif rtype == "IDLM" and name == "MODL":
                fields["model"] = zstr(raw)
            elif rtype == "IDLM" and name == "IDLF" and raw:
                fields["idleFlags"] = raw[0]
            elif rtype == "IDLM" and name == "IDLC" and raw:
                fields["idleCount"] = raw[0] if len(raw) == 1 else u32(raw, 0)
            elif rtype == "IDLM" and name == "IDLT" and len(raw) >= 4:
                fields["idleTimer"] = f32(raw, 0)
            elif rtype == "IDLM" and name == "IDLA" and len(raw) % 4 == 0:
                fields["idleAnimations"] = [
                    form(u32(raw, offset), self.mod_index) for offset in range(0, len(raw), 4)
                ]
            elif rtype == "LIGH" and name == "DATA" and len(raw) in (24, 32, 48, 64):
                fields["light"] = {
                    "time": i32(raw, 0),
                    "radius": u32(raw, 4),
                    "colorRgba": list(raw[8:12]),
                    "flags": i32(raw, 12),
                }
                value_offset = 16
                if len(raw) >= 32:
                    fields["light"]["falloff"] = f32(raw, 16)
                    fields["light"]["fov"] = f32(raw, 20)
                    value_offset = 24 if len(raw) == 32 else len(raw) - 8
                fields["light"]["value"] = u32(raw, value_offset)
                fields["light"]["weight"] = f32(raw, value_offset + 4)
            elif rtype == "LIGH" and name == "FNAM" and len(raw) >= 4:
                fields["lightFade"] = f32(raw, 0)
            elif rtype == "LIGH" and name == "MODL":
                fields["model"] = zstr(raw)
            elif rtype in ("ACTI", "TACT", "DOOR") and name == "MODL":
                fields.setdefault("models", []).append(zstr(raw))
            elif rtype == "ACTI" and name == "SCRI" and len(raw) >= 4:
                fields["script"] = form_from_raw(raw, self.mod_index)
            elif rtype == "ACTI" and name == "SNAM" and len(raw) >= 4:
                fields["loopingSound"] = form_from_raw(raw, self.mod_index)
            elif rtype == "ACTI" and name == "VNAM" and len(raw) >= 4:
                fields["activationSound"] = form_from_raw(raw, self.mod_index)
            elif rtype == "ACTI" and name == "INAM" and len(raw) >= 4:
                fields["radioTemplate"] = form_from_raw(raw, self.mod_index)
            elif rtype == "ACTI" and name == "RNAM" and len(raw) >= 4:
                fields["radioStation"] = form_from_raw(raw, self.mod_index)
            elif rtype == "ACTI" and name == "XATO":
                fields["activationPrompt"] = zstr(raw)
            elif rtype == "TACT" and name == "SCRI" and len(raw) >= 4:
                fields["script"] = form_from_raw(raw, self.mod_index)
            elif rtype == "TACT" and name == "VNAM" and len(raw) >= 4:
                fields["voiceType"] = form_from_raw(raw, self.mod_index)
            elif rtype == "TACT" and name == "SNAM" and len(raw) >= 4:
                fields["loopingSound"] = form_from_raw(raw, self.mod_index)
            elif rtype == "TACT" and name == "INAM" and len(raw) >= 4:
                fields["radioTemplate"] = form_from_raw(raw, self.mod_index)
            elif rtype == "SOUN" and name == "FNAM":
                fields["soundFile"] = zstr(raw)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XTEL" and len(raw) >= 28:
                fields["destDoor"] = form_from_raw(raw, self.mod_index)
                fields["destPos"] = [f32(raw, 4), f32(raw, 8), f32(raw, 12)]
                fields["destRot"] = [f32(raw, 16), f32(raw, 20), f32(raw, 24)]
                fields["teleportFlags"] = u32(raw, 28) if len(raw) >= 32 else 0
                if len(raw) >= 36:
                    fields["transitionInterior"] = form_from_raw(raw[32:], self.mod_index)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "CNAM" and len(raw) >= 4:
                fields["audioLocation"] = form_from_raw(raw, self.mod_index)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XRDO" and len(raw) >= 16:
                fields["radio"] = {
                    "rangeRadius": f32(raw, 0),
                    "broadcastRange": u32(raw, 4),
                    "staticPercentage": f32(raw, 8),
                    "posReference": form_hex(form_from_raw(raw[12:], self.mod_index)),
                }
            elif rtype in ("LVLN", "LVLC") and name == "LVLO" and len(raw) >= 8:
                fields.setdefault("leveledEntries", []).append(form(u32(raw, 4), self.mod_index))
            elif rtype == "LVLI" and name == "LVLO" and len(raw) >= 8:
                # FO3/FNV LVLO is level:u16, padding:u16, item:FormID and
                # optionally count:u16/padding:u16. Preserve the authored
                # branch metadata so actor equipment can be accounted for
                # without guessing from a screenshot.
                fields.setdefault("leveledItemEntries", []).append(
                    {
                        "level": u16(raw, 0),
                        "item": form(u32(raw, 4), self.mod_index),
                        "count": u16(raw, 8) if len(raw) >= 10 else 1,
                    }
                )
            elif rtype == "OTFT" and name == "INAM" and len(raw) % 4 == 0:
                fields.setdefault("outfitItems", []).extend(
                    form(u32(raw, offset), self.mod_index) for offset in range(0, len(raw), 4)
                )
            elif rtype in ("ARMO", "CLOT") and name in ("BMDT", "BODT") and len(raw) >= 4:
                fields["bodyFlags"] = u32(raw, 0)
            elif rtype == "WRLD" and name == "WCTR" and len(raw) >= 4:
                fields["centerCell"] = [struct.unpack_from("<h", raw, 0)[0], struct.unpack_from("<h", raw, 2)[0]]
            elif rtype == "WRLD" and name == "INAM" and len(raw) >= 4:
                fields["imageSpace"] = form_from_raw(raw, self.mod_index)
            elif rtype == "CELL" and name == "XCIM" and len(raw) >= 4:
                fields["imageSpace"] = form_from_raw(raw, self.mod_index)
            elif rtype == "CLMT" and name == "TNAM" and len(raw) >= 6:
                fields["climateTiming"] = {
                    "sunriseBegin": raw[0],
                    "sunriseEnd": raw[1],
                    "sunsetBegin": raw[2],
                    "sunsetEnd": raw[3],
                    "volatility": raw[4],
                    "phaseLength": raw[5],
                }
            elif rtype == "CLMT" and name == "FNAM":
                fields["sunTexture"] = zstr(raw)
            elif rtype == "CLMT" and name == "GNAM":
                fields["sunGlareTexture"] = zstr(raw)
        return fields

    def record_matches_terms(self, item):
        text = " ".join(
            str(item.get(key, ""))
            for key in (
                "editorId",
                "fullName",
                "type",
                "id",
                "parentCell",
                "parentWorld",
                "model",
                "collision",
                "event",
            )
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
                if "settingValue" in fields:
                    record["settingValue"] = fields["settingValue"]
                if "climateTiming" in fields:
                    record["climateTiming"] = fields["climateTiming"]
                if "sunTexture" in fields:
                    record["sunTexture"] = fields["sunTexture"]
                if "sunGlareTexture" in fields:
                    record["sunGlareTexture"] = fields["sunGlareTexture"]
                if "actorFlags" in fields:
                    record["actorFlags"] = fields["actorFlags"]
                if "femaleFlag" in fields:
                    record["femaleFlag"] = fields["femaleFlag"]
                if "race" in fields:
                    record["race"] = form_hex(fields.get("race"))
                    record["openmwRace"] = openmw_form_id(fields.get("race"))
                if "hair" in fields:
                    record["hair"] = form_hex(fields.get("hair"))
                    record["openmwHair"] = openmw_form_id(fields.get("hair"))
                if "eyes" in fields:
                    record["eyes"] = form_hex(fields.get("eyes"))
                    record["openmwEyes"] = openmw_form_id(fields.get("eyes"))
                if "headParts" in fields:
                    record["headParts"] = [form_hex(value) for value in fields["headParts"] if value]
                    record["openmwHeadParts"] = [openmw_form_id(value) for value in fields["headParts"] if value]
                if "baseTemplate" in fields:
                    record["baseTemplate"] = form_hex(fields.get("baseTemplate"))
                    record["openmwBaseTemplate"] = openmw_form_id(fields.get("baseTemplate"))
                if "templateFlags" in fields:
                    record["templateFlags"] = fields["templateFlags"]
                if "hairLength" in fields:
                    record["hairLength"] = fields["hairLength"]
                if "hairColorRgba" in fields:
                    record["hairColorRgba"] = fields["hairColorRgba"]
                if "faceGenFingerprints" in fields:
                    record["faceGenFingerprints"] = fields["faceGenFingerprints"]
                if "models" in fields:
                    record["models"] = fields["models"][:8]
                if "modelSlots" in fields:
                    record["modelSlots"] = fields["modelSlots"][:8]
                if "inventory" in fields:
                    record["inventory"] = [
                        {
                            "item": form_hex(entry["item"]),
                            "openmwItem": openmw_form_id(entry["item"]),
                            "count": entry["count"],
                        }
                        for entry in fields["inventory"]
                        if entry["item"]
                    ]
                for field_name in ("defaultOutfit", "sleepOutfit"):
                    if field_name in fields:
                        record[field_name] = form_hex(fields[field_name])
                        record["openmw" + field_name[0].upper() + field_name[1:]] = openmw_form_id(
                            fields[field_name]
                        )
                if "bodyFlags" in fields:
                    record["bodyFlags"] = fields["bodyFlags"]
                for field_name in ("model", "collision", "event", "idleFlags", "idleCount", "idleTimer"):
                    if field_name in fields:
                        record[field_name] = fields[field_name]
                if "light" in fields:
                    record["light"] = fields["light"]
                    record["light"]["fade"] = fields.get("lightFade", 1.0)
                for field_name in ("parent", "previous"):
                    if field_name in fields:
                        record[field_name] = form_hex(fields[field_name])
                        record["openmw" + field_name[0].upper() + field_name[1:]] = openmw_form_id(
                            fields[field_name]
                        )
                if "conditionData" in fields:
                    record["conditionData"] = fields["conditionData"]
                if "idleAnimations" in fields:
                    record["idleAnimations"] = [form_hex(value) for value in fields["idleAnimations"] if value]
                    record["openmwIdleAnimations"] = [
                        openmw_form_id(value) for value in fields["idleAnimations"] if value
                    ]
                for field_name in (
                    "script",
                    "loopingSound",
                    "activationSound",
                    "radioTemplate",
                    "radioStation",
                    "voiceType",
                ):
                    if field_name in fields:
                        record[field_name] = form_hex(fields[field_name])
                        record["openmw" + field_name[0].upper() + field_name[1:]] = openmw_form_id(fields[field_name])
                for field_name in ("activationPrompt", "soundFile"):
                    if field_name in fields:
                        record[field_name] = fields[field_name]
                if "leveledEntries" in fields:
                    record["leveledEntries"] = [form_hex(entry) for entry in fields["leveledEntries"][:80] if entry]
                    record["openmwLeveledEntries"] = [
                        openmw_form_id(entry) for entry in fields["leveledEntries"][:80] if entry
                    ]
                if "leveledItemEntries" in fields:
                    record["leveledItemEntries"] = [
                        {
                            "level": entry["level"],
                            "item": form_hex(entry["item"]),
                            "openmwItem": openmw_form_id(entry["item"]),
                            "count": entry["count"],
                        }
                        for entry in fields["leveledItemEntries"][:80]
                        if entry["item"]
                    ]
                if "outfitItems" in fields:
                    record["outfitItems"] = [form_hex(entry) for entry in fields["outfitItems"] if entry]
                    record["openmwOutfitItems"] = [openmw_form_id(entry) for entry in fields["outfitItems"] if entry]
                if rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD"):
                    record["parentCell"] = form_hex(current_cell)
                    record["openmwParentCell"] = openmw_form_id(current_cell)
                    record["base"] = form_hex(fields.get("base"))
                    record["openmwBase"] = openmw_form_id(fields.get("base"))
                    record["pos"] = fields.get("pos")
                    record["rot"] = fields.get("rot")
                    record["scale"] = fields.get("scale", 1.0)
                    record["destDoor"] = form_hex(fields.get("destDoor"))
                    record["openmwDestDoor"] = openmw_form_id(fields.get("destDoor"))
                    record["destPos"] = fields.get("destPos")
                    record["destRot"] = fields.get("destRot")
                    record["teleportFlags"] = fields.get("teleportFlags", 0)
                    record["audioLocation"] = form_hex(fields.get("audioLocation"))
                    record["radio"] = fields.get("radio")
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
                    "imageSpace": form_hex(fields.get("imageSpace")),
                    "openmwImageSpace": openmw_form_id(fields.get("imageSpace")),
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
                    "imageSpace": form_hex(fields.get("imageSpace")),
                    "openmwImageSpace": openmw_form_id(fields.get("imageSpace")),
                    "matches": [],
                    "matchedRefs": [],
                    "matchedRefCount": 0,
                    "actorRefCount": 0,
                    "creatureRefCount": 0,
                    "actorRefs": [],
                    "teleportRefs": [],
                    "radioRefs": [],
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
                    "scale": fields.get("scale", 1.0),
                    "editorId": fields.get("editorId", ""),
                    "enableParent": form_hex(fields.get("enableParent")),
                    "openmwEnableParent": openmw_form_id(fields.get("enableParent")),
                    "enableParentFlags": fields.get("enableParentFlags", 0),
                    "destDoor": form_hex(fields.get("destDoor")),
                    "openmwDestDoor": openmw_form_id(fields.get("destDoor")),
                    "destPos": fields.get("destPos"),
                    "destRot": fields.get("destRot"),
                    "teleportFlags": fields.get("teleportFlags", 0),
                    "transitionInterior": form_hex(fields.get("transitionInterior")),
                    "openmwTransitionInterior": openmw_form_id(fields.get("transitionInterior")),
                    "audioLocation": form_hex(fields.get("audioLocation")),
                    "openmwAudioLocation": openmw_form_id(fields.get("audioLocation")),
                    "radio": fields.get("radio"),
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
            cell_int = int(placement["parentCell"], 16)
            cell = self.cells.get(cell_int)
            if cell is not None and placement["type"] in ("ACHR", "ACRE"):
                if placement["type"] == "ACHR":
                    cell["actorRefCount"] += 1
                else:
                    cell["creatureRefCount"] += 1
                if len(cell["actorRefs"]) < 40:
                    base = placement.get("base")
                    base_record = self.records.get(int(base, 16)) if base else None
                    cell["actorRefs"].append(
                        {
                            "ref": placement["id"],
                            "openmwRef": placement["openmwId"],
                            "type": placement["type"],
                            "base": base,
                            "openmwBase": placement.get("openmwBase"),
                            "baseEditorId": base_record.get("editorId", "") if base_record else "",
                            "baseFullName": base_record.get("fullName", "") if base_record else "",
                            "pos": placement.get("pos"),
                            "rot": placement.get("rot"),
                        }
                    )

            if cell is not None and placement.get("destDoor"):
                base = placement.get("base")
                base_record = self.records.get(int(base, 16)) if base else None
                cell["teleportRefs"].append(
                    {
                        "ref": placement["id"],
                        "openmwRef": placement["openmwId"],
                        "base": base,
                        "openmwBase": placement.get("openmwBase"),
                        "baseEditorId": base_record.get("editorId", "") if base_record else "",
                        "baseFullName": base_record.get("fullName", "") if base_record else "",
                        "pos": placement.get("pos"),
                        "rot": placement.get("rot"),
                        "destDoor": placement.get("destDoor"),
                        "openmwDestDoor": placement.get("openmwDestDoor"),
                        "destPos": placement.get("destPos"),
                        "destRot": placement.get("destRot"),
                        "teleportFlags": placement.get("teleportFlags", 0),
                    }
                )

            if cell is not None:
                base = placement.get("base")
                base_record = self.records.get(int(base, 16)) if base else None
                if base_record and (
                    base_record.get("radioStation")
                    or base_record.get("radioTemplate")
                    or placement.get("radio")
                ):
                    cell["radioRefs"].append(
                        {
                            "ref": placement["id"],
                            "openmwRef": placement["openmwId"],
                            "base": base,
                            "openmwBase": placement.get("openmwBase"),
                            "baseEditorId": base_record.get("editorId", ""),
                            "baseFullName": base_record.get("fullName", ""),
                            "pos": placement.get("pos"),
                            "rot": placement.get("rot"),
                            "radioStation": base_record.get("radioStation"),
                            "radioTemplate": base_record.get("radioTemplate"),
                            "audioLocation": placement.get("audioLocation"),
                            "radio": placement.get("radio"),
                        }
                    )

            base = placement.get("base")
            if not base:
                continue
            base_int = int(base, 16)
            if base_int not in base_matches:
                continue
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
            cell["actorTotalRefCount"] = cell["actorRefCount"] + cell["creatureRefCount"]
            cell["score"] = len(cell["matches"]) * 50 + cell["matchedRefCount"] + cell["actorTotalRefCount"] * 5
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
            if len(cell["actorRefs"]) > 20:
                cell["actorRefs"] = cell["actorRefs"][:20]
            if len(cell["teleportRefs"]) > 40:
                cell["teleportRefs"] = cell["teleportRefs"][:40]
            if len(cell["radioRefs"]) > 40:
                cell["radioRefs"] = cell["radioRefs"][:40]

        cells = sorted(self.cells.values(), key=lambda c: (c["score"], c["matchedRefCount"]), reverse=True)
        top_cells = [cell for cell in cells if cell["score"] > 0][:200]
        top_actor_cells = sorted(
            (cell for cell in self.cells.values() if cell["actorTotalRefCount"] > 0),
            key=lambda c: (c["actorTotalRefCount"], c["actorRefCount"], c["score"]),
            reverse=True,
        )[:200]
        worlds = sorted(self.worlds.values(), key=lambda w: w.get("editorId", ""))
        teleport_refs = []
        radio_refs = []
        light_refs = []
        for cell in self.cells.values():
            for ref in cell["teleportRefs"]:
                teleport_refs.append(
                    {
                        "cell": cell["id"],
                        "openmwCell": cell["openmwId"],
                        "cellEditorId": cell["editorId"],
                        "cellFullName": cell["fullName"],
                        "cellIsExterior": cell["isExterior"],
                        **ref,
                    }
                )
            for ref in cell["radioRefs"]:
                radio_refs.append(
                    {
                        "cell": cell["id"],
                        "openmwCell": cell["openmwId"],
                        "cellEditorId": cell["editorId"],
                        "cellFullName": cell["fullName"],
                        "cellIsExterior": cell["isExterior"],
                        **ref,
                    }
                )
        for placement in self.placements:
            base = placement.get("base")
            if not base:
                continue
            base_record = self.records.get(int(base, 16))
            if not base_record or base_record.get("type") != "LIGH":
                continue
            cell = self.cells.get(int(placement["parentCell"], 16))
            light_refs.append(
                {
                    "ref": placement["id"],
                    "openmwRef": placement["openmwId"],
                    "cell": placement["parentCell"],
                    "cellEditorId": cell.get("editorId", "") if cell else "",
                    "base": base,
                    "openmwBase": placement.get("openmwBase"),
                    "baseEditorId": base_record.get("editorId", ""),
                    "model": base_record.get("model", ""),
                    "light": base_record.get("light"),
                    "pos": placement.get("pos"),
                    "rot": placement.get("rot"),
                    "scale": placement.get("scale", 1.0),
                }
            )
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
                "lightRefs": len(light_refs),
            },
            "worlds": worlds,
            "termRecords": term_records[:1000],
            "teleportRefs": teleport_refs,
            "radioRefs": radio_refs,
            "lightRefs": light_refs,
            "topCells": top_cells,
            "topActorCells": top_actor_cells,
        }


def main():
    parser = argparse.ArgumentParser(description="Export a narrow ESM4 cell/ref catalog for world-viewer starts.")
    parser.add_argument("--esm", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mod-index", type=int, default=0)
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
