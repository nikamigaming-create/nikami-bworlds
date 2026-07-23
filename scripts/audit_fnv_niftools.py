#!/usr/bin/env python3
"""Parse FNV NIF/KF/EGM assets with the pinned NifTools PyFFI oracle."""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pyffi-root", type=Path, required=True)
    parser.add_argument("assets", type=Path, nargs="+")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sys.path.insert(0, str(args.pyffi_root.resolve()))

    from pyffi.formats.egm import EgmFormat
    from pyffi.formats.nif import NifFormat

    results: list[dict[str, object]] = []
    for asset in args.assets:
        path = asset.resolve()
        suffix = path.suffix.lower()
        with path.open("rb") as stream:
            if suffix in {".nif", ".kf"}:
                data = NifFormat.Data()
                data.read(stream)
                block_types = collections.Counter(type(block).__name__ for block in data.blocks)
                results.append(
                    {
                        "path": str(path),
                        "format": suffix[1:].upper(),
                        "version": f"0x{data.version:08x}",
                        "userVersion": data.user_version,
                        "blocks": len(data.blocks),
                        "roots": len(data.roots),
                        "topBlockTypes": block_types.most_common(8),
                    }
                )
            elif suffix == ".egm":
                data = EgmFormat.Data()
                data.read(stream)
                results.append(
                    {
                        "path": str(path),
                        "format": "EGM",
                        "version": data.version,
                        "vertices": data.header.num_vertices,
                        "symmetricMorphs": len(data.sym_morphs),
                        "asymmetricMorphs": len(data.asym_morphs),
                    }
                )
            else:
                raise ValueError(f"Unsupported asset extension: {path}")

    print(json.dumps({"status": "pass", "assets": results}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
