#!/usr/bin/env python3
"""Audit FO3/FNV SDP shader packages without committing retail bytecode.

The Bethesda package header contains a vertex-shader count, total entry count,
and payload byte count, followed by fixed 256-byte names and sized bytecode
blobs. Selected blobs and Microsoft fxc disassembly are written only to the
declared output directory (normally ignored ``run/retail-oracle`` storage).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ShaderEntry:
    index: int
    name: str
    bytecode: bytes


def fnv1a32(data: bytes) -> int:
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return value


def read_package(path: Path) -> tuple[int, int, int, bytes, list[ShaderEntry]]:
    data = path.read_bytes()
    if len(data) < 12:
        raise ValueError("SDP file is shorter than its 12-byte header")
    vertex_count, total_count, payload_bytes = struct.unpack_from("<III", data, 0)
    if total_count < vertex_count:
        raise ValueError("SDP total entry count is smaller than vertex entry count")
    if payload_bytes != len(data) - 12:
        raise ValueError(
            f"SDP payload byte count mismatch: header={payload_bytes}, actual={len(data) - 12}"
        )

    entries: list[ShaderEntry] = []
    offset = 12
    for index in range(total_count):
        if offset + 260 > len(data):
            raise ValueError(f"SDP entry {index} header exceeds the package")
        raw_name = data[offset : offset + 256]
        offset += 256
        name = raw_name.split(b"\0", 1)[0].decode("ascii", errors="strict")
        byte_count = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        end = offset + byte_count
        if end > len(data):
            raise ValueError(f"SDP entry {index} bytecode exceeds the package")
        entries.append(ShaderEntry(index=index, name=name, bytecode=data[offset:end]))
        offset = end

    if offset != len(data):
        raise ValueError(f"SDP parser left {len(data) - offset} trailing bytes")
    return vertex_count, total_count, payload_bytes, data, entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, type=Path, help="Retail shaderpackageNNN.sdp")
    parser.add_argument(
        "--name", action="append", default=[], help="Exact shader name to select; repeat as needed"
    )
    parser.add_argument("--output-dir", type=Path, help="Quarantine directory for selected bytecode")
    parser.add_argument("--fxc", type=Path, help="Optional Microsoft fxc.exe used with /dumpbin")
    args = parser.parse_args()

    vertex_count, total_count, payload_bytes, package_data, entries = read_package(args.package)
    wanted = set(args.name)
    selected = [entry for entry in entries if not wanted or entry.name in wanted]
    missing = sorted(wanted - {entry.name for entry in selected})
    if missing:
        raise SystemExit(f"Shader name(s) not found: {', '.join(missing)}")

    output_dir = args.output_dir.resolve() if args.output_dir else None
    if (args.fxc or wanted) and output_dir is None:
        raise SystemExit("--output-dir is required when selecting or disassembling shaders")
    if output_dir:
        output_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict[str, object]] = []
    for entry in selected:
        row: dict[str, object] = {
            "index": entry.index,
            "kind": "vertex" if entry.index < vertex_count else "pixel-or-effect",
            "name": entry.name,
            "byteCount": len(entry.bytecode),
            "fnv1a32": f"0x{fnv1a32(entry.bytecode):08X}",
            "sha256": hashlib.sha256(entry.bytecode).hexdigest(),
        }
        if output_dir:
            bytecode_path = output_dir / entry.name
            bytecode_path.write_bytes(entry.bytecode)
            row["bytecodeFile"] = bytecode_path.name
            if args.fxc:
                disassembly = subprocess.run(
                    [str(args.fxc), "/nologo", "/dumpbin", str(bytecode_path)],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
                assembly_path = output_dir / f"{entry.name}.asm"
                assembly_path.write_text(disassembly, encoding="ascii", newline="\n")
                row["disassemblyFile"] = assembly_path.name
        rows.append(row)

    manifest = {
        "schema": "nikami-fallout-shader-package-audit/v1",
        "packageName": args.package.name,
        "packageByteCount": len(package_data),
        "packageSha256": hashlib.sha256(package_data).hexdigest(),
        "vertexEntryCount": vertex_count,
        "totalEntryCount": total_count,
        "payloadByteCount": payload_bytes,
        "selected": rows,
        "retailAssetPolicy": "Keep extracted bytecode in ignored quarantine; commit metadata only.",
    }
    encoded = json.dumps(manifest, indent=2) + "\n"
    if output_dir:
        (output_dir / "shader-package-manifest.json").write_text(encoded, encoding="utf-8", newline="\n")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
