from __future__ import annotations

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("export_opennv_resolved_database.py")
SPEC = importlib.util.spec_from_file_location("export_opennv_resolved_database", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TOOL
SPEC.loader.exec_module(TOOL)


def subrecord(name: str, payload: bytes = b"") -> bytes:
    return name.encode("ascii") + struct.pack("<H", len(payload)) + payload


def record(rtype: str, form_id: int, payload: bytes = b"", flags: int = 0) -> bytes:
    return rtype.encode("ascii") + struct.pack("<III", len(payload), flags, form_id) + struct.pack("<IHH", 0, 0, 0) + payload


def group(records: list[bytes]) -> bytes:
    payload = b"".join(records)
    return b"GRUP" + struct.pack("<I", 24 + len(payload)) + b"TEST" + struct.pack("<IHHHH", 0, 0, 0, 0, 0) + payload


def plugin(path: Path, masters: list[str], records: list[bytes]) -> None:
    header = subrecord("HEDR", struct.pack("<fII", 1.34, len(records), 0x800))
    for master in masters:
        header += subrecord("MAST", master.encode() + b"\0") + subrecord("DATA", struct.pack("<Q", 0))
    path.write_bytes(record("TES4", 0, header) + group(records))


class ResolvedDatabaseTest(unittest.TestCase):
    def test_winning_override_and_delete_are_sharded_with_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / "Data"
            data.mkdir()
            base = data / "FalloutNV.esm"
            dlc = data / "DeadMoney.esm"
            plugin(base, [], [
                record("NPC_", 0x100),
                record("ACHR", 0x200, subrecord("NAME", struct.pack("<I", 0x100))),
            ])
            plugin(dlc, ["FalloutNV.esm"], [
                record("NPC_", 0x100, flags=0x20),
                record("CREA", 0x01000300),
            ])
            bootstrap = root / "bootstrap.json"
            bootstrap.write_text(json.dumps({"load_order": ["FalloutNV.esm", "DeadMoney.esm"]}))
            output = root / "resolved"
            result = TOOL.compile_database(bootstrap_path=bootstrap, data_root=data, output_dir=output)
            self.assertEqual(result["counts"]["physical"], 4)
            self.assertEqual(result["counts"]["winning"], 3)
            self.assertEqual(result["counts"]["deleted_winners"], 1)
            self.assertEqual(result["counts"]["overridden_physical"], 1)
            npc = json.loads((output / "records" / "npc_.json").read_text())["records"]
            self.assertEqual(npc[0]["source_plugin"], "DeadMoney.esm")
            self.assertEqual(npc[0]["override_chain"], ["FalloutNV.esm", "DeadMoney.esm"])
            achr = json.loads((output / "records" / "achr.json").read_text())["records"]
            self.assertEqual(achr[0]["base_form_id"], "0x00000100")


if __name__ == "__main__":
    unittest.main()
