#!/usr/bin/env python3
"""Mine public-safe string context from Starfield's local materialsbeta.cdb.

The script does not copy or decode retail assets. It reports offsets, nearby
strings, and texture/material path candidates so renderer patches can be tied
back to the local material database.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Iterable


ASCII_RE = re.compile(rb"[\x20-\x7e]{4,}")
TEXTURE_RE = re.compile(
    r"(?i)(?:data[\\/])?textures[\\/][^\s\x00]+?\.(?:dds|png|tga)"
)
MATERIAL_RE = re.compile(
    r"(?i)(?:data[\\/])?materials[\\/][^\s\x00]+?\.mat(?:_Material\d+)?"
)


def iter_ascii_strings(data: bytes, start: int = 0, end: int | None = None) -> Iterable[tuple[int, str]]:
    chunk = data[start:end]
    for match in ASCII_RE.finditer(chunk):
        yield start + match.start(), match.group().decode("ascii", "ignore")


def normalized_candidate(value: str) -> str:
    value = value.strip().strip('"')
    value = value.replace("\\", "/")
    if value.lower().startswith("data/"):
        value = value[5:]
    return value


def unique_preserve_order(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        key = value.lower()
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def collect_context(data: bytes, offset: int, context_bytes: int) -> dict[str, object]:
    start = max(0, offset - context_bytes)
    end = min(len(data), offset + context_bytes)
    strings = [
        {"offset": string_offset, "value": value}
        for string_offset, value in iter_ascii_strings(data, start, end)
    ]
    text_blob = "\n".join(item["value"] for item in strings)
    texture_candidates = unique_preserve_order(
        normalized_candidate(match.group(0)) for match in TEXTURE_RE.finditer(text_blob)
    )
    material_candidates = unique_preserve_order(
        normalized_candidate(match.group(0)) for match in MATERIAL_RE.finditer(text_blob)
    )
    return {
        "contextStart": start,
        "contextEnd": end,
        "strings": strings,
        "textureCandidates": texture_candidates,
        "materialCandidates": material_candidates,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cdb", type=Path, help="Path to local materialsbeta.cdb")
    parser.add_argument(
        "--query",
        action="append",
        default=[],
        help="Case-insensitive string to search for. Repeat for multiple queries.",
    )
    parser.add_argument("--context-bytes", type=int, default=1024)
    parser.add_argument("--max-hits", type=int, default=12)
    parser.add_argument("--out", type=Path, default=None, help="Optional JSON output path")
    args = parser.parse_args()

    data = args.cdb.read_bytes()
    lowered = data.lower()
    hits: list[dict[str, object]] = []

    for query in args.query:
        needle = query.encode("utf-8").lower()
        start = 0
        query_hits = 0
        while query_hits < args.max_hits:
            offset = lowered.find(needle, start)
            if offset < 0:
                break
            context = collect_context(data, offset, args.context_bytes)
            hits.append(
                {
                    "query": query,
                    "offset": offset,
                    **context,
                }
            )
            query_hits += 1
            start = offset + 1

    result = {
        "schemaVersion": 1,
        "cdb": str(args.cdb),
        "size": len(data),
        "queries": args.query,
        "contextBytes": args.context_bytes,
        "hits": hits,
    }

    text = json.dumps(result, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
