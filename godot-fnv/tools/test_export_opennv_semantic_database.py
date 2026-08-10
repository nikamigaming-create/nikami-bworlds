from __future__ import annotations

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("export_opennv_semantic_database.py")
SPEC = importlib.util.spec_from_file_location("export_opennv_semantic_database", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TOOL
SPEC.loader.exec_module(TOOL)


def subrecord(name: str, payload: bytes = b"") -> bytes:
    return name.encode() + struct.pack("<H", len(payload)) + payload


def record(kind: str, form_id: int, payload: bytes = b"", flags: int = 0) -> bytes:
    return kind.encode() + struct.pack("<III", len(payload), flags, form_id) + struct.pack("<IHH", 0, 0, 0) + payload


def group(label: bytes, group_type: int, children: list[bytes]) -> bytes:
    payload = b"".join(children)
    return b"GRUP" + struct.pack("<I", 24 + len(payload)) + label + struct.pack("<IHHHH", group_type, 0, 0, 0, 0) + payload


def plugin(path: Path, masters: list[str], children: list[bytes]) -> None:
    header = subrecord("HEDR", struct.pack("<fII", 1.34, 0, 0x800))
    for master in masters:
        header += subrecord("MAST", master.encode() + b"\0") + subrecord("DATA", bytes(8))
    path.write_bytes(record("TES4", 0, header) + group(b"TEST", 0, children))


class SemanticDatabaseTest(unittest.TestCase):
    def test_master_reference_and_winning_actor_override(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / "Data"
            data.mkdir()
            base = data / "FalloutNV.esm"
            dlc = data / "DeadMoney.esm"
            plugin(base, [], [record("NPC_", 0x100, subrecord("EDID", b"BaseActor\0"))])
            plugin(dlc, ["FalloutNV.esm"], [
                record("NPC_", 0x100, subrecord("EDID", b"OverrideActor\0")),
                record("CREA", 0x01000300, subrecord("TPLT", struct.pack("<I", 0x00000100))),
            ])
            bootstrap = root / "bootstrap.json"
            bootstrap.write_text(json.dumps({"load_order": ["FalloutNV.esm", "DeadMoney.esm"]}))
            # Produce the authoritative resolved manifest with the sibling tool.
            resolved_tool_path = SCRIPT.with_name("export_opennv_resolved_database.py")
            spec = importlib.util.spec_from_file_location("semantic_test_resolved", resolved_tool_path)
            resolved_tool = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = resolved_tool
            spec.loader.exec_module(resolved_tool)
            resolved_dir = root / "resolved"
            resolved_tool.compile_database(bootstrap_path=bootstrap, data_root=data, output_dir=resolved_dir)
            output = root / "semantic"
            result = TOOL.compile_semantics(
                bootstrap_path=bootstrap, data_root=data,
                resolved_manifest_path=resolved_dir / "manifest.json", output_dir=output)
            self.assertEqual(result["counts"]["actor_bases"], 2)
            actors = json.loads((output / "actor-bases.json").read_text())["actors"]
            by_id = {row["id"]: row for row in actors}
            self.assertEqual(by_id["0x100"]["editorId"], "OverrideActor")
            self.assertEqual(by_id["0x1000300"]["baseTemplate"], "0x100")


if __name__ == "__main__":
    unittest.main()
