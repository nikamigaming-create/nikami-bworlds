#!/usr/bin/env python3
"""Compile master-resolved winning ESM4 records for the Godot runtime.

This deliberately shares the audited master-table and decompression machinery
used by ``scripts/export_fnv_parity_corpus.py``.  It is a record-index layer,
not the final semantic compiler: later actor/world/quest compilers consume its
winning records and must add type-specific payloads without reimplementing
load-order resolution.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from collections import Counter, defaultdict
from pathlib import Path


def _load_corpus(repo_root: Path):
    source = repo_root / "scripts" / "export_fnv_parity_corpus.py"
    spec = importlib.util.spec_from_file_location("opennv_parity_corpus", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load parity corpus module: {source}")
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve their defining module through sys.modules.
    import sys
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _form(value: int | None) -> str | None:
    return None if value is None else f"0x{value:08x}"


def compile_database(*, bootstrap_path: Path, data_root: Path, output_dir: Path) -> dict:
    repo_root = Path(__file__).resolve().parents[2]
    corpus = _load_corpus(repo_root)
    bootstrap = json.loads(bootstrap_path.read_text(encoding="utf-8"))
    load_order = [str(value) for value in bootstrap.get("load_order", [])]
    if not load_order:
        raise RuntimeError("bootstrap load_order is empty")
    plugin_paths = [(data_root / name).resolve() for name in load_order]
    missing = [str(path) for path in plugin_paths if not path.is_file()]
    if missing:
        raise RuntimeError("missing load-order plugins: " + ", ".join(missing))

    sources = corpus.inspect_plugins(plugin_paths)
    if [source.name for source in sources] != load_order:
        raise RuntimeError("resolved plugin order differs from bootstrap")
    by_name = {source.name.casefold(): source for source in sources}

    physical_by_type: Counter[str] = Counter()
    chains: dict[int, list] = defaultdict(list)
    unresolvable = 0
    for source in sources:
        for record in corpus.iter_plugin_records(source, by_name):
            physical_by_type[record.rtype] += 1
            if record.form_id is None:
                unresolvable += 1
                continue
            chains[record.form_id].append(record)

    winners = {form_id: chain[-1] for form_id, chain in chains.items()}
    winning_by_type = Counter(record.rtype for record in winners.values())
    live_by_type = Counter(record.rtype for record in winners.values() if not record.deleted)
    output_dir.mkdir(parents=True, exist_ok=True)
    shard_dir = output_dir / "records"
    shard_dir.mkdir(parents=True, exist_ok=True)

    records_by_type: dict[str, list[dict]] = defaultdict(list)
    for form_id, record in sorted(winners.items()):
        chain = chains[form_id]
        row = {
            "form_id": _form(form_id),
            "type": record.rtype,
            "flags": record.flags,
            "deleted": record.deleted,
            "source_index": record.source_index,
            "source_plugin": sources[record.source_index].name,
            "base_form_id": _form(record.base),
        }
        if record.metrics:
            row["subrecord_counts"] = dict(record.metrics)
        if record.editor_id:
            row["editor_id"] = record.editor_id
        if record.full_name:
            row["full_name"] = record.full_name
        if record.cell_flags is not None:
            row["cell_flags"] = record.cell_flags
        if record.water_types:
            row["water_types"] = [_form(value) for value in record.water_types]
        if len(chain) > 1:
            row["override_chain"] = [sources[item.source_index].name for item in chain]
        records_by_type[record.rtype].append(row)

    shard_entries = []
    for rtype in sorted(records_by_type):
        payload = {
            "schema": "opennv-resolved-record-shard/v1",
            "type": rtype,
            "records": records_by_type[rtype],
        }
        encoded = _canonical_json(payload)
        path = shard_dir / f"{rtype.lower()}.json"
        path.write_bytes(encoded)
        shard_entries.append({
            "type": rtype,
            "path": f"records/{path.name}",
            "sha256": hashlib.sha256(encoded).hexdigest(),
            "winning": len(records_by_type[rtype]),
            "live": live_by_type[rtype],
        })

    plugin_rows = [{
        "index": source.load_index,
        "name": source.name,
        "masters": list(source.masters),
        "path": str(source.path).replace("\\", "/"),
        "size": source.size,
        "sha256": source.sha256,
        "localized": source.localized,
    } for source in sources]
    load_order_sha256 = hashlib.sha256(_canonical_json(plugin_rows)).hexdigest()
    shard_set_sha256 = hashlib.sha256(_canonical_json(shard_entries)).hexdigest()
    manifest = {
        "schema": "opennv-resolved-record-database/v1",
        "bootstrap": str(bootstrap_path.resolve()).replace("\\", "/"),
        "bootstrap_sha256": hashlib.sha256(bootstrap_path.read_bytes()).hexdigest(),
        "load_order_sha256": load_order_sha256,
        "shard_set_sha256": shard_set_sha256,
        "plugins": plugin_rows,
        "counts": {
            "physical": sum(physical_by_type.values()),
            "unresolvable_physical": unresolvable,
            "winning": len(winners),
            "live": sum(not record.deleted for record in winners.values()),
            "deleted_winners": sum(record.deleted for record in winners.values()),
            "overridden_physical": sum(max(0, len(chain) - 1) for chain in chains.values()),
            "override_chains": sum(len(chain) > 1 for chain in chains.values()),
        },
        "types": {
            rtype: {
                "physical": physical_by_type[rtype],
                "winning": winning_by_type[rtype],
                "live": live_by_type[rtype],
            }
            for rtype in sorted(set(physical_by_type) | set(winning_by_type))
        },
        "shards": shard_entries,
    }
    encoded_manifest = json.dumps(manifest, indent=2, ensure_ascii=False).encode("utf-8") + b"\n"
    (output_dir / "manifest.json").write_bytes(encoded_manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    manifest = compile_database(
        bootstrap_path=args.bootstrap.resolve(),
        data_root=args.data_root.resolve(),
        output_dir=args.output_dir.resolve(),
    )
    print("OPENNV_RESOLVED_DATABASE " + json.dumps(manifest["counts"], sort_keys=True))
    print(f"OPENNV_RESOLVED_LOAD_ORDER sha256={manifest['load_order_sha256']} plugins={len(manifest['plugins'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
