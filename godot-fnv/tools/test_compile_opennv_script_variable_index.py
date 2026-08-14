#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("compile_opennv_script_variable_index.py")
SPEC = importlib.util.spec_from_file_location("compile_opennv_script_variable_index", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)
compile_index = MODULE.compile_index
digest = MODULE.digest


class ScriptVariableIndexTests(unittest.TestCase):
    def write(self, root: Path, name: str, payload: object) -> None:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def test_resolves_explicit_reference_and_rejects_null_semantics_without_inventing_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write(root, "manifest.json", {"schema": "opennv-semantic-database/v1", "load_order_sha256": "test", "counts": {"placements": 1}})
            self.write(root, "scripts.json", {"schema": "opennv-semantic-scripts/v1", "scripts": [
                {"id": "0x100", "scriptLocals": [{"index": 1, "name": "State", "type": 1}]},
            ]})
            self.write(root, "placement-bases.json", {"schema": "opennv-semantic-placement-bases/v1", "records": [
                {"id": "0x200", "script": "0x100"},
            ]})
            self.write(root, "script-owners.json", {"schema": "opennv-semantic-script-owners/v1", "owners": [
                {"id": "0x200", "script": "0x100"},
            ]})
            self.write(root, "actor-bases.json", {"actors": []})
            self.write(root, "actor-lists.json", {"lists": []})
            self.write(root, "actor-placements.json", {"placements": []})
            self.write(root, "actor-blueprints.json", {
                "schema": "opennv-actor-blueprints/v1",
                "semantic_manifest_sha256": digest(root / "manifest.json"),
                "actor_bases_sha256": digest(root / "actor-bases.json"),
                "actor_lists_sha256": digest(root / "actor-lists.json"),
                "actor_placements_sha256": digest(root / "actor-placements.json"),
                "blueprints": [
                {"id": "0x200", "script": "0x100", "packages": ["0x300"]},
            ]})
            self.write(root, "actor-packages.json", {"schema": "opennv-semantic-actor-packages/v1", "packages": [{"id": "0x300", "conditionData": [
                {"functionId": 53, "param1": None, "param2Raw": 1},
                {"functionId": 53, "param1": "0x400", "param2Raw": 1},
            ]}]})
            for index in range(256):
                self.write(root, f"placements/{index:02x}.json", {"placements": [
                    {"id": "0x400", "base": "0x200"},
                ] if index == 0 else []})
            result = compile_index(root, root / "index.json")
            self.assertEqual(result["counts"]["function53Conditions"], 2)
            self.assertEqual(result["counts"]["function53ExplicitReferenceRows"], 1)
            self.assertEqual(result["counts"]["function53NullReferenceRows"], 1)
            self.assertEqual(result["counts"]["definitionResolvedExplicitRows"], 1)
            self.assertEqual(result["counts"]["liveValueResolvedExplicitRows"], 0)
            explicit = next(row for row in result["function53"] if row["targetMode"] == "reference")
            self.assertEqual(explicit["localName"], "State")
            self.assertEqual(explicit["targetReference"], "0x00000400")
            self.assertFalse(explicit["liveValueResolved"])


if __name__ == "__main__":
    unittest.main()
