#!/usr/bin/env python3
"""Export the exact active xNVSE-provider footprint of an untouched JAM ESP."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import struct
import sys
import zlib
from pathlib import Path

from audit_fnv_quest_bytecode import iter_records
from export_esm4_catalog import ESM4Catalog, REC_COMPRESSED, subrecords, zstr


PROVIDER_IDS = ("xnvse-core", "jip-ln", "johnnyguitar", "knvse")
MODULE_PREFIXES = ("JDC", "JHI", "JHM", "JHB", "JVS", "JVO", "JWH", "JLM", "JBT")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest().upper()


def strip_cpp_comments(text: str) -> str:
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.DOTALL)


def strip_geck_comments(text: str) -> str:
    output: list[str] = []
    for line in text.splitlines():
        quoted = False
        escaped = False
        kept: list[str] = []
        for char in line:
            if char == '"' and not escaped:
                quoted = not quoted
            if char == ";" and not quoted:
                break
            kept.append(char)
            escaped = char == "\\" and not escaped
            if char != "\\":
                escaped = False
        output.append("".join(kept))
    return "\n".join(output)


def read_source(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def registered_commands(
    xnvse_root: Path, jip_root: Path, johnny_root: Path, knvse_root: Path
) -> dict[str, set[str]]:
    xnvse_table = strip_cpp_comments(
        read_source(xnvse_root / "nvse" / "nvse" / "CommandTable.cpp")
    )
    jip_table = strip_cpp_comments(read_source(jip_root / "jip_nvse.cpp"))
    johnny_text = "\n".join(
        strip_cpp_comments(read_source(path))
        for path in (johnny_root / "JG" / "functions").rglob("*")
        if path.suffix.lower() in {".h", ".hpp", ".cpp"}
    )
    knvse_table = strip_cpp_comments(
        read_source(knvse_root / "nvse_plugin_example" / "main.cpp")
    )

    result = {
        "xnvse-core": set(
            re.findall(
                r"\b(?:ADD_CMD|ADD_CMD_RET|ADD_CMD_VER|ADD_CMD_VER_RET)"
                r"\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)",
                xnvse_table,
            )
        ),
        "jip-ln": set(
            re.findall(
                r"\bREG_CMD(?:_FRM|_STR|_ARR|_AMB)?"
                r"\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)",
                jip_table,
            )
        ),
        "johnnyguitar": set(
            re.findall(
                r"DEFINE_COMMAND(?:_ALT)?_PLUGIN"
                r"\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)",
                johnny_text,
            )
        ),
        "knvse": set(
            re.findall(
                r"\bREG_CMD(?:_TYPED)?\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)",
                knvse_table,
            )
        ),
    }
    for commands in result.values():
        commands.difference_update({"name", "command"})
    return result


def extract_sctx(plugin: Path) -> list[dict[str, object]]:
    catalog = ESM4Catalog(plugin)
    scripts: list[dict[str, object]] = []
    for kind, flags, form_id, payload in iter_records(
        catalog.data, catalog.header_size, 0, len(catalog.data)
    ):
        if flags & REC_COMPRESSED:
            try:
                payload = zlib.decompress(payload[4:])
            except zlib.error:
                continue
        editor_id = ""
        sources: list[str] = []
        try:
            for name, raw in subrecords(payload):
                if name == "EDID" and not editor_id:
                    editor_id = zstr(raw)
                elif name == "SCTX":
                    sources.append(
                        raw.rstrip(b"\0").decode("cp1252", errors="replace")
                    )
        except (IndexError, struct.error):
            continue
        for source_index, source in enumerate(sources):
            module = next(
                (prefix for prefix in MODULE_PREFIXES if editor_id.startswith(prefix)),
                "OTHER",
            )
            scripts.append(
                {
                    "recordType": kind.decode("ascii", errors="replace"),
                    "formId": f"0x{form_id:08X}",
                    "editorId": editor_id,
                    "sourceIndex": source_index,
                    "module": module,
                    "source": source,
                    "activeSource": strip_geck_comments(source),
                }
            )
    return scripts

def symbol_rows(
    scripts: list[dict[str, object]], command_set: set[str]
) -> list[dict[str, object]]:
    canonical = {command.lower(): command for command in command_set}
    hits: dict[str, dict[str, object]] = {}
    for script in scripts:
        tokens = re.findall(
            r"[A-Za-z_][A-Za-z0-9_]*", str(script["activeSource"])
        )
        for token in tokens:
            command = canonical.get(token.lower())
            if command is None:
                continue
            row = hits.setdefault(
                command.lower(),
                {
                    "symbol": command,
                    "occurrences": 0,
                    "scripts": collections.Counter(),
                    "modules": collections.Counter(),
                },
            )
            row["occurrences"] = int(row["occurrences"]) + 1
            row["scripts"][str(script["editorId"])] += 1
            row["modules"][str(script["module"])] += 1

    rows: list[dict[str, object]] = []
    for row in hits.values():
        rows.append(
            {
                "symbol": row["symbol"],
                "occurrences": row["occurrences"],
                "scripts": [
                    {"id": key, "occurrences": value}
                    for key, value in sorted(row["scripts"].items())
                ],
                "modules": [
                    {"id": key, "occurrences": value}
                    for key, value in sorted(row["modules"].items())
                ],
            }
        )
    return sorted(rows, key=lambda row: str(row["symbol"]).lower())


def language_semantics(scripts: list[dict[str, object]]) -> dict[str, int]:
    active = "\n".join(str(script["activeSource"]) for script in scripts)
    return {
        "functionBlocks": len(
            re.findall(r"(?im)^\s*begin\s+function\b", active)
        ),
        "evalStatements": len(re.findall(r"(?im)^\s*eval\b", active)),
        "evalExpressions": len(re.findall(r"(?i)\beval\b", active)),
        "arrayVarDeclarations": len(
            re.findall(r"(?im)^\s*array_var\s+", active)
        ),
        "stringVarDeclarations": len(
            re.findall(r"(?im)^\s*string_var\s+", active)
        ),
        "indexedArrayExpressions": len(
            re.findall(r"\b[A-Za-z_][A-Za-z0-9_.]*\s*\[[^\]\r\n]+\]", active)
        ),
        "stringInterpolationExpressions": len(
            re.findall(r"\$[A-Za-z_][A-Za-z0-9_.]*", active)
        ),
    }


def asset_inventory(root: Path) -> dict[str, int]:
    counts = collections.Counter(
        path.suffix.lower() for path in root.rglob("*") if path.is_file()
    )
    return {
        extension.lstrip("."): counts[extension]
        for extension in (".esp", ".xml", ".txt", ".dds", ".nif", ".kf", ".wav")
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jam-root", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--xnvse-root", type=Path, required=True)
    parser.add_argument("--jip-root", type=Path, required=True)
    parser.add_argument("--johnny-root", type=Path, required=True)
    parser.add_argument("--knvse-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    plugin = args.jam_root / "JustAssortedMods.esp"
    required_paths = [
        plugin,
        args.xnvse_root / "nvse" / "nvse" / "CommandTable.cpp",
        args.jip_root / "jip_nvse.cpp",
        args.johnny_root / "JG" / "functions",
        args.knvse_root / "nvse_plugin_example" / "main.cpp",
    ]
    if args.archive is not None:
        required_paths.append(args.archive)
    missing = [str(path) for path in required_paths if not path.exists()]
    if missing:
        parser.error("missing input(s): " + ", ".join(missing))

    scripts = extract_sctx(plugin)
    command_sets = registered_commands(
        args.xnvse_root, args.jip_root, args.johnny_root, args.knvse_root
    )
    providers: list[dict[str, object]] = []
    active_by_provider: dict[str, set[str]] = {}
    for provider_id in PROVIDER_IDS:
        rows = symbol_rows(scripts, command_sets[provider_id])
        active_by_provider[provider_id] = {
            str(row["symbol"]).lower() for row in rows
        }
        providers.append(
            {
                "id": provider_id,
                "registeredSymbolsScanned": len(command_sets[provider_id]),
                "activeUniqueSymbols": len(rows),
                "activeOccurrences": sum(int(row["occurrences"]) for row in rows),
                "symbols": rows,
            }
        )

    ambiguities: list[dict[str, object]] = []
    all_symbols = set().union(*active_by_provider.values())
    for symbol in sorted(all_symbols):
        owners = [
            provider_id
            for provider_id in PROVIDER_IDS
            if symbol in active_by_provider[provider_id]
        ]
        if len(owners) > 1:
            ambiguities.append({"symbol": symbol, "providers": owners})

    modules = []
    for module in MODULE_PREFIXES:
        module_scripts = [
            str(script["editorId"]) for script in scripts if script["module"] == module
        ]
        modules.append(
            {
                "id": module,
                "scriptCount": len(module_scripts),
                "scripts": sorted(module_scripts),
            }
        )

    result = {
        "schemaVersion": 1,
        "contractId": "fnv-jam-4.6-full-parity-v1",
        "provenance": {
            "plugin": plugin.name,
            "pluginSha256": sha256(plugin),
            "archive": args.archive.name if args.archive else None,
            "archiveSha256": sha256(args.archive) if args.archive else None,
        },
        "sctx": {
            "count": len(scripts),
            "scripts": [
                {
                    key: script[key]
                    for key in (
                        "recordType",
                        "formId",
                        "editorId",
                        "sourceIndex",
                        "module",
                    )
                }
                for script in scripts
            ],
        },
        "modules": modules,
        "languageSemantics": language_semantics(scripts),
        "providers": providers,
        "providerOwnershipAmbiguities": ambiguities,
        "assets": asset_inventory(args.jam_root),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print(
        f"SCTX={len(scripts)} "
        + " ".join(
            f"{row['id']}={row['activeUniqueSymbols']}/{row['activeOccurrences']}"
            for row in providers
        )
    )
    print(
        "semantics="
        + " ".join(
            f"{key}:{value}" for key, value in result["languageSemantics"].items()
        )
    )
    print(f"ownershipAmbiguities={len(ambiguities)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
