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

CONDITION_FORM_PARAM1_FUNCTIONS = {
    1, 47, 67, 68, 69, 71, 72, 74, 79, 84, 110, 180, 214, 237, 258,
    277, 278, 280, 282, 285, 286, 300, 365, 398, 408, 409, 448, 449, 450,
}
CONDITION_OPERATORS = {
    0x00: "equal",
    0x20: "not_equal",
    0x40: "greater",
    0x60: "greater_or_equal",
    0x80: "less",
    0xA0: "less_or_equal",
}


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
    def __init__(self, path, mod_index=0, terms=None, form_resolver=None):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.mod_index = mod_index
        self.form_resolver = form_resolver
        self.terms = [term.lower() for term in (terms or []) if term]
        self.header_size = self.detect_header_size()
        self.localized = False
        self.records = {}
        self.worlds = {}
        self.cells = {}
        self.placements = []
        self.navmeshes = {}

    def resolve_form(self, raw_form):
        if raw_form == 0:
            return None
        return self.form_resolver(raw_form) if self.form_resolver is not None else form(raw_form, self.mod_index)

    def resolve_form_from_raw(self, raw):
        return self.resolve_form(u32(raw, 0)) if len(raw) >= 4 else None

    def parse_condition(self, name, raw):
        if len(raw) not in (20, 24, 28, 36):
            return {"subrecord": name, "bytes": len(raw), "hex": raw.hex(), "supportedLayout": False}
        flags = u32(raw, 0)
        comparison_bits = u32(raw, 4)
        function_id = u16(raw, 8)
        param1_raw = u32(raw, 12)
        param2_raw = u32(raw, 16)
        if len(raw) == 20:
            param3_raw, run_on, reference_raw = None, 0, 0
        elif len(raw) == 24:
            param3_raw, run_on, reference_raw = None, u32(raw, 20), 0
        elif len(raw) == 28:
            param3_raw, run_on, reference_raw = None, u32(raw, 20), u32(raw, 24)
        else:
            param3_raw, run_on, reference_raw = u32(raw, 20), u32(raw, 24), u32(raw, 28)
        uses_global = (flags & 0x04) != 0
        return {
            "subrecord": name,
            "bytes": len(raw),
            "supportedLayout": True,
            "flags": flags,
            "orWithNext": (flags & 0x01) != 0,
            "runOnTarget": (flags & 0x02) != 0,
            "comparisonUsesGlobal": uses_global,
            "operator": CONDITION_OPERATORS.get(flags & 0xE0, "unsupported"),
            "comparison": None if uses_global else f32(raw, 4),
            "comparisonGlobal": self.resolve_form(comparison_bits) if uses_global else None,
            "functionId": function_id,
            "functionWordHigh": u16(raw, 10),
            "param1": self.resolve_form(param1_raw)
            if function_id in CONDITION_FORM_PARAM1_FUNCTIONS else param1_raw,
            "param1IsForm": function_id in CONDITION_FORM_PARAM1_FUNCTIONS and param1_raw != 0,
            "param1Raw": param1_raw,
            "param2Raw": param2_raw,
            "param3Raw": param3_raw,
            "runOn": run_on,
            "reference": self.resolve_form(reference_raw),
            "referenceRaw": reference_raw,
        }

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
        current_land_layer = None
        navmesh_parts = {}
        for name, raw in subrecords(payload):
            if rtype == "NAVM" and name in {
                "NVER", "DATA", "NVVX", "NVTR", "NVCA", "NVDP", "NVGD", "NVEX"
            }:
                navmesh_parts[name] = raw
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
            elif rtype == "LAND" and name == "VHGT" and len(raw) >= 4 + (33 * 33):
                fields["heightOffset"] = f32(raw, 0)
                fields["heightDeltas"] = list(struct.unpack_from("<1089b", raw, 4))
            elif rtype == "LAND" and name == "BTXT" and len(raw) >= 8:
                fields.setdefault("baseTextures", []).append(
                    {
                        "texture": self.resolve_form_from_raw(raw),
                        "quadrant": raw[4],
                    }
                )
                current_land_layer = None
            elif rtype == "LAND" and name == "ATXT" and len(raw) >= 8:
                current_land_layer = {
                    "texture": self.resolve_form_from_raw(raw),
                    "quadrant": raw[4],
                    "layer": u16(raw, 6),
                    "vertices": [],
                }
                fields.setdefault("alphaTextures", []).append(current_land_layer)
            elif rtype == "LAND" and name == "VTXT" and current_land_layer is not None:
                # One VTXT subrecord contains sparse 8-byte vertex entries:
                # quadrant-local vertex index, padding, and authored opacity.
                for offset in range(0, len(raw) - 7, 8):
                    current_land_layer["vertices"].append(
                        {"index": u16(raw, offset), "opacity": f32(raw, offset + 4)}
                    )
            elif rtype == "NAVM" and name == "NVNM":
                fields["navmeshData"] = self.parse_navmesh_nvnm(raw)
            elif rtype == "LTEX" and name == "ICON":
                fields["landTexture"] = zstr(raw)
            elif rtype == "LTEX" and name == "TNAM" and len(raw) >= 4:
                fields["textureSet"] = self.resolve_form_from_raw(raw)
            elif rtype == "TXST" and name == "TX00":
                fields["diffuseTexture"] = zstr(raw)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "NAME" and len(raw) >= 4:
                fields["base"] = self.resolve_form(u32(raw, 0))
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "DATA" and len(raw) >= 24:
                fields["pos"] = [f32(raw, 0), f32(raw, 4), f32(raw, 8)]
                fields["rot"] = [f32(raw, 12), f32(raw, 16), f32(raw, 20)]
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XSCL" and len(raw) >= 4:
                fields["scale"] = f32(raw, 0)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XESP" and len(raw) >= 8:
                fields["enableParent"] = self.resolve_form_from_raw(raw)
                fields["enableParentFlags"] = u32(raw, 4)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XOWN" and len(raw) >= 4:
                fields["owner"] = self.resolve_form_from_raw(raw)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XGLB" and len(raw) >= 4:
                fields["global"] = self.resolve_form_from_raw(raw)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XRNK" and len(raw) >= 4:
                fields["factionRank"] = i32(raw, 0)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XCNT" and len(raw) >= 4:
                fields["count"] = i32(raw, 0)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XLOC" and len(raw) >= 8:
                fields["isLocked"] = True
                fields["lockLevel"] = struct.unpack_from("<b", raw, 0)[0]
                fields["lockKey"] = self.resolve_form_from_raw(raw[4:])
                fields["lockDataBytes"] = len(raw)
            elif rtype in ("NPC_", "CREA") and name == "ACBS" and len(raw) >= 4:
                fields["actorFlags"] = u32(raw, 0)
                # TES4-family actor flags use bit 0 for female on the games we mine here.
                fields["femaleFlag"] = (fields["actorFlags"] & 1) != 0
            elif rtype == "NPC_" and name == "RNAM" and len(raw) >= 4:
                fields["race"] = self.resolve_form_from_raw(raw)
            elif rtype == "NPC_" and name == "HNAM" and len(raw) >= 4:
                fields["hair"] = self.resolve_form_from_raw(raw)
            elif rtype == "NPC_" and name == "ENAM" and len(raw) >= 4:
                fields["eyes"] = self.resolve_form_from_raw(raw)
            elif rtype == "NPC_" and name == "PNAM" and len(raw) >= 4:
                fields.setdefault("headParts", []).append(self.resolve_form_from_raw(raw))
            elif rtype in ("NPC_", "CREA") and name == "TPLT" and len(raw) >= 4:
                fields["baseTemplate"] = self.resolve_form_from_raw(raw)
            elif rtype in ("NPC_", "CREA") and name == "EAMT" and len(raw) >= 2:
                fields["templateFlags"] = u16(raw, 0)
            elif rtype in ("NPC_", "CREA") and name == "PKID" and len(raw) >= 4:
                fields.setdefault("packages", []).append(self.resolve_form_from_raw(raw))
            elif rtype == "PACK" and name == "PKDT" and len(raw) >= 4:
                package_data = {"flags": u32(raw, 0), "type": 0}
                if len(raw) >= 12:
                    package_data.update(
                        type=raw[4],
                        procedureFlags=u16(raw, 6),
                        typeSpecificFlags=u16(raw, 8),
                    )
                elif len(raw) >= 8:
                    package_data["type"] = i32(raw, 4)
                fields["packageData"] = package_data
            elif rtype == "PACK" and name == "PSDT" and len(raw) >= 8:
                fields["packageSchedule"] = {
                    "month": raw[0],
                    "dayOfWeek": raw[1],
                    "date": raw[2],
                    "time": raw[3],
                    "duration": u32(raw, 4),
                }
            elif rtype == "PACK" and name in ("PLDT", "PLD2") and len(raw) >= 12:
                location_type = i32(raw, 0)
                raw_location = u32(raw, 4)
                location = raw_location if location_type == 5 else self.resolve_form(raw_location)
                entry = {
                    "type": location_type,
                    "location": location,
                    "locationIsForm": location_type != 5,
                    "radius": i32(raw, 8),
                }
                if name == "PLDT":
                    fields["packageLocation"] = entry
                else:
                    fields.setdefault("packageExtraLocations", []).append(entry)
            elif rtype == "PACK" and name in ("PTDT", "PTD2") and len(raw) >= 12:
                target_type = i32(raw, 0)
                raw_target = u32(raw, 4)
                target = raw_target if target_type == 2 else self.resolve_form(raw_target)
                entry = {
                    "type": target_type,
                    "target": target,
                    "targetIsForm": target_type != 2,
                    "distance": i32(raw, 8),
                }
                if len(raw) >= 16:
                    entry["unknown"] = f32(raw, 12)
                if name == "PTDT":
                    fields["packageTarget"] = entry
                else:
                    fields.setdefault("packageExtraTargets", []).append(entry)
            elif rtype == "PACK" and name in ("CTDA", "CTDT"):
                fields.setdefault("conditionData", []).append(self.parse_condition(name, raw))
            elif rtype == "PACK" and name == "IDLF" and raw:
                fields["packageIdleFlags"] = raw[0] if len(raw) == 1 else u32(raw, 0) & 0xff
            elif rtype == "PACK" and name == "IDLC" and raw:
                fields["packageIdleCount"] = raw[0] if len(raw) == 1 else u32(raw, 0)
            elif rtype == "PACK" and name == "IDLT" and len(raw) >= 4:
                fields["packageIdleTimer"] = f32(raw, 0)
            elif rtype == "PACK" and name == "IDLA" and len(raw) % 4 == 0:
                fields["packageIdleAnimations"] = [
                    self.resolve_form(u32(raw, offset)) for offset in range(0, len(raw), 4)
                ]
            elif rtype in ("NPC_", "CREA", "CONT") and name == "CNTO" and len(raw) >= 8:
                fields.setdefault("inventory", []).append(
                    {
                        "item": self.resolve_form_from_raw(raw),
                        "count": i32(raw, 4),
                    }
                )
            elif rtype == "NPC_" and name == "DOFT" and len(raw) >= 4:
                fields["defaultOutfit"] = self.resolve_form_from_raw(raw)
            elif rtype == "NPC_" and name == "SOFT" and len(raw) >= 4:
                fields["sleepOutfit"] = self.resolve_form_from_raw(raw)
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
            elif name == "MODL" and rtype in (
                "STAT", "SCOL", "MSTT", "ACTI", "TACT", "DOOR", "CONT",
                "FURN", "LIGH", "TREE", "GRAS", "PWAT", "ANIO", "PROJ",
                "AMMO", "MISC", "KEYM", "BOOK", "ALCH", "INGR",
            ):
                # World-runtime consumers need the authored render model for
                # every placeable base family, not only actors/equipment.
                fields["model"] = zstr(raw)
            elif rtype == "IDLE" and name == "MODL":
                fields["model"] = zstr(raw)
            elif rtype == "TERM" and name == "DNAM":
                fields["terminalDataBytes"] = list(raw)
            elif rtype == "IDLE" and name == "DNAM":
                fields["collision"] = zstr(raw)
            elif rtype == "IDLE" and name == "ENAM":
                fields["event"] = zstr(raw)
            elif rtype == "IDLE" and name == "ANAM" and len(raw) >= 8:
                fields["parent"] = self.resolve_form_from_raw(raw)
                fields["previous"] = self.resolve_form_from_raw(raw[4:])
            elif rtype == "IDLE" and name in ("CTDA", "CTDT"):
                fields.setdefault("conditionData", []).append(self.parse_condition(name, raw))
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
                    self.resolve_form(u32(raw, offset)) for offset in range(0, len(raw), 4)
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
                fields["script"] = self.resolve_form_from_raw(raw)
            elif rtype == "ACTI" and name == "SNAM" and len(raw) >= 4:
                fields["loopingSound"] = self.resolve_form_from_raw(raw)
            elif rtype == "ACTI" and name == "VNAM" and len(raw) >= 4:
                fields["activationSound"] = self.resolve_form_from_raw(raw)
            elif rtype == "ACTI" and name == "INAM" and len(raw) >= 4:
                fields["radioTemplate"] = self.resolve_form_from_raw(raw)
            elif rtype == "ACTI" and name == "RNAM" and len(raw) >= 4:
                fields["radioStation"] = self.resolve_form_from_raw(raw)
            elif rtype == "ACTI" and name == "XATO":
                fields["activationPrompt"] = zstr(raw)
            elif rtype == "TACT" and name == "SCRI" and len(raw) >= 4:
                fields["script"] = self.resolve_form_from_raw(raw)
            elif rtype == "TACT" and name == "VNAM" and len(raw) >= 4:
                fields["voiceType"] = self.resolve_form_from_raw(raw)
            elif rtype == "TACT" and name == "SNAM" and len(raw) >= 4:
                fields["loopingSound"] = self.resolve_form_from_raw(raw)
            elif rtype == "TACT" and name == "INAM" and len(raw) >= 4:
                fields["radioTemplate"] = self.resolve_form_from_raw(raw)
            elif rtype == "SOUN" and name == "FNAM":
                fields["soundFile"] = zstr(raw)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XTEL" and len(raw) >= 28:
                fields["destDoor"] = self.resolve_form_from_raw(raw)
                fields["destPos"] = [f32(raw, 4), f32(raw, 8), f32(raw, 12)]
                fields["destRot"] = [f32(raw, 16), f32(raw, 20), f32(raw, 24)]
                fields["teleportFlags"] = u32(raw, 28) if len(raw) >= 32 else 0
                if len(raw) >= 36:
                    fields["transitionInterior"] = self.resolve_form_from_raw(raw[32:])
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "CNAM" and len(raw) >= 4:
                fields["audioLocation"] = self.resolve_form_from_raw(raw)
            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and name == "XRDO" and len(raw) >= 16:
                fields["radio"] = {
                    "rangeRadius": f32(raw, 0),
                    "broadcastRange": u32(raw, 4),
                    "staticPercentage": f32(raw, 8),
                    "posReference": form_hex(self.resolve_form_from_raw(raw[12:])),
                }
            elif rtype in ("LVLN", "LVLC") and name == "LVLO" and len(raw) >= 8:
                item = self.resolve_form(u32(raw, 4))
                fields.setdefault("leveledEntries", []).append(item)
                fields.setdefault("leveledActorEntries", []).append({
                    "level": u16(raw, 0),
                    "item": item,
                    "count": u16(raw, 8) if len(raw) >= 10 else 1,
                })
            elif rtype in ("LVLN", "LVLC") and name == "LVLD" and len(raw) >= 1:
                fields["chanceNone"] = raw[0]
            elif rtype in ("LVLN", "LVLC") and name == "LVLF" and len(raw) >= 1:
                fields["leveledFlags"] = raw[0]
            elif rtype in ("LVLN", "LVLC") and name == "LLCT" and len(raw) >= 1:
                fields["leveledListCount"] = raw[0]
            elif rtype in ("LVLN", "LVLC") and name == "TNAM" and len(raw) >= 4:
                fields["leveledTemplate"] = self.resolve_form_from_raw(raw)
            elif rtype == "LVLI" and name == "LVLO" and len(raw) >= 8:
                # FO3/FNV LVLO is level:u16, padding:u16, item:FormID and
                # optionally count:u16/padding:u16. Preserve the authored
                # branch metadata so actor equipment can be accounted for
                # without guessing from a screenshot.
                fields.setdefault("leveledItemEntries", []).append(
                    {
                        "level": u16(raw, 0),
                        "item": self.resolve_form(u32(raw, 4)),
                        "count": u16(raw, 8) if len(raw) >= 10 else 1,
                    }
                )
            elif rtype == "OTFT" and name == "INAM" and len(raw) % 4 == 0:
                fields.setdefault("outfitItems", []).extend(
                    self.resolve_form(u32(raw, offset)) for offset in range(0, len(raw), 4)
                )
            elif rtype in ("ARMO", "CLOT") and name in ("BMDT", "BODT") and len(raw) >= 4:
                fields["bodyFlags"] = u32(raw, 0)
            elif rtype == "WRLD" and name == "WCTR" and len(raw) >= 4:
                fields["centerCell"] = [struct.unpack_from("<h", raw, 0)[0], struct.unpack_from("<h", raw, 2)[0]]
            elif rtype == "WRLD" and name == "INAM" and len(raw) >= 4:
                fields["imageSpace"] = self.resolve_form_from_raw(raw)
            elif rtype == "CELL" and name == "XCIM" and len(raw) >= 4:
                fields["imageSpace"] = self.resolve_form_from_raw(raw)
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
        if rtype == "NAVM" and "navmeshData" not in fields and navmesh_parts:
            fields["navmeshData"] = self.parse_navmesh_split(navmesh_parts)
        return fields

    def parse_navmesh_split(self, parts):
        """Decode the FO3/FNV split NAVM layout defined by xEdit.

        DATA owns all array counts. Every array is length-checked against that
        header so corrupt or misunderstood records fail compilation instead of
        producing plausible-looking navigation.
        """
        required = {"NVER", "DATA", "NVVX", "NVTR", "NVGD"}
        missing = sorted(required.difference(parts))
        if missing:
            raise ValueError(f"{self.path.name}: NAVM missing required subrecords {missing}")
        if len(parts["NVER"]) != 4:
            raise ValueError(f"{self.path.name}: NAVM NVER is {len(parts['NVER'])} bytes, expected 4")
        data = parts["DATA"]
        if len(data) != 24:
            raise ValueError(f"{self.path.name}: NAVM DATA is {len(data)} bytes, expected 24")

        version = u32(parts["NVER"], 0)
        cell = self.resolve_form(u32(data, 0))
        vertex_count, triangle_count, edge_count, cover_count, door_count = struct.unpack_from("<5I", data, 4)
        for label, count in (
            ("vertices", vertex_count), ("triangles", triangle_count),
            ("edge links", edge_count), ("cover triangles", cover_count),
            ("door links", door_count),
        ):
            if count > 1_000_000:
                raise ValueError(f"{self.path.name}: absurd NAVM {label} count {count}")

        vertices_raw = parts["NVVX"]
        if len(vertices_raw) != vertex_count * 12:
            raise ValueError(
                f"{self.path.name}: NAVM NVVX is {len(vertices_raw)} bytes, expected {vertex_count * 12}"
            )
        vertices = [list(struct.unpack_from("<3f", vertices_raw, index * 12)) for index in range(vertex_count)]

        triangles_raw = parts["NVTR"]
        if len(triangles_raw) != triangle_count * 16:
            raise ValueError(
                f"{self.path.name}: NAVM NVTR is {len(triangles_raw)} bytes, expected {triangle_count * 16}"
            )
        triangles = []
        for index in range(triangle_count):
            values = struct.unpack_from("<3H3h2H", triangles_raw, index * 16)
            vertex_indices = list(values[:3])
            if any(vertex >= vertex_count for vertex in vertex_indices):
                raise ValueError(
                    f"{self.path.name}: NAVM triangle {index} references vertex {vertex_indices} / {vertex_count}"
                )
            triangles.append({
                "vertices": vertex_indices,
                "edges": list(values[3:6]),
                "flags": values[6],
                "coverFlags": values[7],
            })

        covers_raw = parts.get("NVCA", b"")
        if len(covers_raw) != cover_count * 2:
            raise ValueError(
                f"{self.path.name}: NAVM NVCA is {len(covers_raw)} bytes, expected {cover_count * 2}"
            )
        covers = list(struct.unpack_from(f"<{cover_count}H", covers_raw, 0)) if cover_count else []
        if any(triangle >= triangle_count for triangle in covers):
            raise ValueError(f"{self.path.name}: NAVM cover triangle index is out of range")

        doors_raw = parts.get("NVDP", b"")
        if len(doors_raw) != door_count * 8:
            raise ValueError(
                f"{self.path.name}: NAVM NVDP is {len(doors_raw)} bytes, expected {door_count * 8}"
            )
        doors = []
        invalid_door_triangles = 0
        for index in range(door_count):
            raw_door, triangle, unused = struct.unpack_from("<IHH", doors_raw, index * 8)
            if triangle >= triangle_count:
                # The shipped masters contain broken door links. Preserve and
                # count them so the compiler/runtime can quarantine the edge;
                # never reinterpret the bytes or silently discard the record.
                invalid_door_triangles += 1
            doors.append({
                "door": form_hex(self.resolve_form(raw_door)),
                "triangle": triangle,
                "unused": unused,
            })

        edges_raw = parts.get("NVEX", b"")
        if len(edges_raw) != edge_count * 10:
            raise ValueError(
                f"{self.path.name}: NAVM NVEX is {len(edges_raw)} bytes, expected {edge_count * 10}"
            )
        external = []
        for index in range(edge_count):
            edge_type, raw_navmesh, triangle = struct.unpack_from("<IIH", edges_raw, index * 10)
            external.append({
                "type": edge_type,
                "navmesh": form_hex(self.resolve_form(raw_navmesh)),
                "triangle": triangle,
            })

        grid_raw = parts["NVGD"]
        if len(grid_raw) < 36:
            raise ValueError(f"{self.path.name}: NAVM NVGD is {len(grid_raw)} bytes, expected at least 36")
        divisor = u32(grid_raw, 0)
        if divisor > 4096:
            raise ValueError(f"{self.path.name}: absurd NAVM grid divisor {divisor}")
        grid_offset = 36
        grid_cells = []
        for cell_index in range(divisor * divisor):
            if grid_offset + 2 > len(grid_raw):
                raise ValueError(f"{self.path.name}: truncated NAVM grid cell {cell_index}")
            count = u16(grid_raw, grid_offset)
            grid_offset += 2
            byte_count = count * 2
            if grid_offset + byte_count > len(grid_raw):
                raise ValueError(f"{self.path.name}: truncated NAVM grid cell triangles {cell_index}")
            indices = list(struct.unpack_from(f"<{count}H", grid_raw, grid_offset)) if count else []
            if any(triangle >= triangle_count for triangle in indices):
                raise ValueError(f"{self.path.name}: NAVM grid triangle index is out of range")
            grid_cells.append(indices)
            grid_offset += byte_count
        if grid_offset != len(grid_raw):
            raise ValueError(
                f"{self.path.name}: NAVM NVGD has {len(grid_raw) - grid_offset} unexplained trailing bytes"
            )

        return {
            "encoding": "fo3-fnv-split",
            "version": version,
            "cell": form_hex(cell),
            "vertices": vertices,
            "triangles": triangles,
            "externalConnections": external,
            "doorTriangles": doors,
            "invalidDoorTriangleCount": invalid_door_triangles,
            "coverTriangles": covers,
            "segmentDivisor": divisor,
            "segmentTriangleCount": sum(len(indices) for indices in grid_cells),
            "bounds": {
                "maxXDistance": f32(grid_raw, 4),
                "maxYDistance": f32(grid_raw, 8),
                "minimum": [f32(grid_raw, 12), f32(grid_raw, 16), f32(grid_raw, 20)],
                "maximum": [f32(grid_raw, 24), f32(grid_raw, 28), f32(grid_raw, 32)],
            },
            "bytes": sum(len(raw) for raw in parts.values()),
            "trailingBytes": 0,
        }

    def parse_navmesh_nvnm(self, raw):
        """Decode the FO3/FNV NVNM topology consumed by OpenMW's NavMesh loader."""
        offset = 0

        def require(size, label):
            if offset + size > len(raw):
                raise ValueError(f"{self.path.name}: truncated NAVM {label} at {offset}/{len(raw)}")

        def read_u16(label):
            nonlocal offset
            require(2, label)
            value = u16(raw, offset)
            offset += 2
            return value

        def read_u32(label):
            nonlocal offset
            require(4, label)
            value = u32(raw, offset)
            offset += 4
            return value

        def read_f32(label):
            nonlocal offset
            require(4, label)
            value = f32(raw, offset)
            offset += 4
            return value

        version = read_u32("version")
        location = read_u32("location")
        raw_world = read_u32("world")
        world = self.resolve_form(raw_world)
        # FO3/FNV encode the owning CELL after the worldspace. The alternate
        # grid branch in OpenMW is for the older Tamriel/Skywind identifiers.
        cell = self.resolve_form(read_u32("cell"))
        vertex_count = read_u32("vertex-count")
        if vertex_count > 1_000_000:
            raise ValueError(f"{self.path.name}: absurd NAVM vertex count {vertex_count}")
        vertices = []
        for _ in range(vertex_count):
            vertices.append([read_f32("vertex-x"), read_f32("vertex-y"), read_f32("vertex-z")])
        triangle_count = read_u32("triangle-count")
        if triangle_count > 1_000_000:
            raise ValueError(f"{self.path.name}: absurd NAVM triangle count {triangle_count}")
        triangles = []
        for _ in range(triangle_count):
            triangles.append([read_u16("triangle-field") for _field in range(8)])
        external_count = read_u32("external-count")
        external = []
        for _ in range(external_count):
            unknown = read_u32("external-unknown")
            navmesh = self.resolve_form(read_u32("external-navmesh"))
            external.append({"unknown": unknown, "navmesh": form_hex(navmesh), "triangle": read_u16("external-triangle")})
        door_count = read_u32("door-count")
        doors = []
        for _ in range(door_count):
            triangle = read_u16("door-triangle")
            unknown = read_u32("door-unknown")
            door = self.resolve_form(read_u32("door-reference"))
            doors.append({"triangle": triangle, "unknown": unknown, "door": form_hex(door)})
        cover_count = read_u32("cover-count")
        covers = [read_u16("cover-triangle") for _ in range(cover_count)]
        divisor = read_u32("segment-divisor")
        bounds = {
            "maxXDistance": read_f32("max-x-distance"),
            "maxYDistance": read_f32("max-y-distance"),
            "minimum": [read_f32("min-x"), read_f32("min-y"), read_f32("min-z")],
            "maximum": [read_f32("max-x"), read_f32("max-y"), read_f32("max-z")],
        }
        segment_triangle_count = 0
        for _ in range(divisor * divisor):
            count = read_u32("segment-triangle-count")
            segment_triangle_count += count
            for _index in range(count):
                read_u16("segment-triangle")
        return {
            "version": version,
            "location": location,
            "world": form_hex(world),
            "cell": form_hex(cell),
            "vertices": vertices,
            "triangles": triangles,
            "externalConnections": external,
            "doorTriangles": doors,
            "coverTriangles": covers,
            "segmentDivisor": divisor,
            "segmentTriangleCount": segment_triangle_count,
            "bounds": bounds,
            "bytes": len(raw),
            "trailingBytes": len(raw) - offset,
        }

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
                    child_world = self.resolve_form(u32(label, 0))
                elif group_type in (6, 8, 9, 10):
                    child_cell = self.resolve_form(u32(label, 0))
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
            rec_form = self.resolve_form(raw_form)
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
                    "recordFlags": flags,
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
                if "packages" in fields:
                    record["packages"] = [form_hex(value) for value in fields["packages"] if value]
                    record["openmwPackages"] = [openmw_form_id(value) for value in fields["packages"] if value]
                if "packageData" in fields:
                    record["packageData"] = fields["packageData"]
                if "packageSchedule" in fields:
                    record["packageSchedule"] = fields["packageSchedule"]
                for field_name, output_name, value_name in (
                    ("packageLocation", "packageLocation", "location"),
                    ("packageTarget", "packageTarget", "target"),
                ):
                    if field_name in fields:
                        entry = dict(fields[field_name])
                        value = entry[value_name]
                        entry[value_name] = form_hex(value) if entry.pop(value_name + "IsForm") else value
                        record[output_name] = entry
                for field_name, output_name, value_name in (
                    ("packageExtraLocations", "packageExtraLocations", "location"),
                    ("packageExtraTargets", "packageExtraTargets", "target"),
                ):
                    if field_name in fields:
                        record[output_name] = []
                        for source_entry in fields[field_name]:
                            entry = dict(source_entry)
                            value = entry[value_name]
                            entry[value_name] = form_hex(value) if entry.pop(value_name + "IsForm") else value
                            record[output_name].append(entry)
                for field_name in ("packageIdleFlags", "packageIdleCount", "packageIdleTimer"):
                    if field_name in fields:
                        record[field_name] = fields[field_name]
                if "packageIdleAnimations" in fields:
                    record["packageIdleAnimations"] = [
                        form_hex(value) for value in fields["packageIdleAnimations"] if value
                    ]
                if rtype == "PACK" and "conditionData" in fields:
                    record["conditionData"] = fields["conditionData"]
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
                if "terminalDataBytes" in fields:
                    record["terminalDataBytes"] = fields["terminalDataBytes"]
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
                if "landTexture" in fields:
                    record["landTexture"] = fields["landTexture"]
                if "textureSet" in fields:
                    record["textureSet"] = form_hex(fields["textureSet"])
                if "diffuseTexture" in fields:
                    record["diffuseTexture"] = fields["diffuseTexture"]
                if "navmeshData" in fields:
                    record["navmeshData"] = fields["navmeshData"]
                    record["parentCell"] = fields["navmeshData"].get("cell") or form_hex(current_cell)
                if "leveledEntries" in fields:
                    record["leveledEntries"] = [form_hex(entry) for entry in fields["leveledEntries"][:80] if entry]
                    record["openmwLeveledEntries"] = [
                        openmw_form_id(entry) for entry in fields["leveledEntries"][:80] if entry
                    ]
                if "leveledActorEntries" in fields:
                    record["leveledActorEntries"] = [
                        {
                            "level": entry["level"],
                            "item": form_hex(entry["item"]),
                            "count": entry["count"],
                        }
                        for entry in fields["leveledActorEntries"]
                        if entry["item"]
                    ]
                for field_name in ("chanceNone", "leveledFlags", "leveledListCount"):
                    if field_name in fields:
                        record[field_name] = fields[field_name]
                if "leveledTemplate" in fields:
                    record["leveledTemplate"] = form_hex(fields["leveledTemplate"])
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
                    record["recordFlags"] = flags
                    record["parentCell"] = form_hex(current_cell)
                    record["openmwParentCell"] = openmw_form_id(current_cell)
                    record["base"] = form_hex(fields.get("base"))
                    record["openmwBase"] = openmw_form_id(fields.get("base"))
                    record["pos"] = fields.get("pos")
                    record["rot"] = fields.get("rot")
                    record["scale"] = fields.get("scale", 1.0)
                    record["enableParent"] = form_hex(fields.get("enableParent"))
                    record["openmwEnableParent"] = openmw_form_id(fields.get("enableParent"))
                    record["enableParentFlags"] = fields.get("enableParentFlags", 0)
                    record["destDoor"] = form_hex(fields.get("destDoor"))
                    record["openmwDestDoor"] = openmw_form_id(fields.get("destDoor"))
                    record["destPos"] = fields.get("destPos")
                    record["destRot"] = fields.get("destRot")
                    record["teleportFlags"] = fields.get("teleportFlags", 0)
                    record["audioLocation"] = form_hex(fields.get("audioLocation"))
                    record["radio"] = fields.get("radio")
                    record["owner"] = form_hex(fields.get("owner"))
                    record["openmwOwner"] = openmw_form_id(fields.get("owner"))
                    record["global"] = form_hex(fields.get("global"))
                    record["openmwGlobal"] = openmw_form_id(fields.get("global"))
                    record["factionRank"] = fields.get("factionRank", -1)
                    record["count"] = fields.get("count", 1)
                    record["isLocked"] = fields.get("isLocked", False)
                    record["lockLevel"] = fields.get("lockLevel", 0)
                    record["lockKey"] = form_hex(fields.get("lockKey"))
                    record["openmwLockKey"] = openmw_form_id(fields.get("lockKey"))
                    record["lockDataBytes"] = fields.get("lockDataBytes", 0)
                matches = self.record_matches_terms(record)
                if matches:
                    record["matches"] = matches
                self.records[rec_form] = record
                if rtype == "NAVM" and "navmeshData" in fields:
                    self.navmeshes[rec_form] = record

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

            elif rtype == "LAND" and current_cell is not None and current_cell in self.cells:
                if "heightDeltas" in fields:
                    self.cells[current_cell]["land"] = {
                        "formId": form_hex(rec_form),
                        "heightOffset": fields["heightOffset"],
                        "heightDeltas": fields["heightDeltas"],
                        "baseTextures": [
                            {"texture": form_hex(row["texture"]), "quadrant": row["quadrant"]}
                            for row in fields.get("baseTextures", []) if row.get("texture")
                        ],
                        "alphaTextures": [
                            {
                                "texture": form_hex(row["texture"]),
                                "quadrant": row["quadrant"],
                                "layer": row["layer"],
                                "vertices": row["vertices"],
                            }
                            for row in fields.get("alphaTextures", []) if row.get("texture")
                        ],
                    }

            elif rtype in ("REFR", "ACHR", "ACRE", "PGRE", "PHZD") and rec_form is not None and current_cell is not None:
                placement = {
                    "id": form_hex(rec_form),
                    "openmwId": openmw_form_id(rec_form),
                    "type": rtype,
                    "recordFlags": flags,
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
                    "owner": form_hex(fields.get("owner")),
                    "openmwOwner": openmw_form_id(fields.get("owner")),
                    "global": form_hex(fields.get("global")),
                    "openmwGlobal": openmw_form_id(fields.get("global")),
                    "factionRank": fields.get("factionRank", -1),
                    "count": fields.get("count", 1),
                    "isLocked": fields.get("isLocked", False),
                    "lockLevel": fields.get("lockLevel", 0),
                    "lockKey": form_hex(fields.get("lockKey")),
                    "openmwLockKey": openmw_form_id(fields.get("lockKey")),
                    "lockDataBytes": fields.get("lockDataBytes", 0),
                }
                placement["matches"] = self.record_matches_terms(placement)
                self.placements.append(placement)

            offset = data_end

    def build_output(self):
        term_records = []
        for record in self.records.values():
            if record.get("matches"):
                term_records.append(record)

        term_placements = [placement for placement in self.placements if placement.get("matches")]

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
                "navmeshes": len(self.navmeshes),
                "termRecords": len(term_records),
                "lightRefs": len(light_refs),
            },
            "worlds": worlds,
            "termRecords": term_records[:1000],
            "termPlacements": term_placements[:1000],
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
