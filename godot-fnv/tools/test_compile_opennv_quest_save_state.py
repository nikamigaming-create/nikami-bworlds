from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("compile_opennv_quest_save_state.py")
SPEC = importlib.util.spec_from_file_location("compile_opennv_quest_save_state", MODULE_PATH)
assert SPEC and SPEC.loader
compiler = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = compiler
SPEC.loader.exec_module(compiler)


class QuestSaveStateTest(unittest.TestCase):
    def test_merges_authored_defaults_and_saved_runtime_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            semantic = root / "semantic"
            semantic.mkdir()
            quests_path = semantic / "quests.json"
            scripts_path = semantic / "scripts.json"
            quests_path.write_text(json.dumps({"schema": "opennv-semantic-quests/v1", "quests": [{
                "id": "0x100", "type": "QUST", "script": "0x200",
                "questData": {"flags": 1, "priority": 50, "delay": 5.0},
            }]}))
            scripts_path.write_text(json.dumps({"schema": "opennv-semantic-scripts/v1", "scripts": [{
                "id": "0x200", "scriptLocals": [{"index": 1, "name": "State"}, {"index": 2, "name": "Target"}],
                "scriptLocalReferenceIndices": [2],
            }]}))
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            (semantic / "manifest.json").write_text(json.dumps({
                "schema": "opennv-semantic-database/v1", "load_order_sha256": "load",
                "artifacts": [
                    {"path": "quests.json", "sha256": digest(quests_path)},
                    {"path": "scripts.json", "sha256": digest(scripts_path)},
                ],
            }))
            overlay = root / "overlay.json"
            overlay.write_text(json.dumps({
                "schema": "opennv-fos-changeform-index/v1", "source": {"sha256": "save"},
                "changeForms": [{
                    "refId": {"resolvedFormId": "0x100"},
                    "questState": {
                        "flags": 0x23,
                        "stages": [{"id": 10, "done": True}],
                        "objectives": [{"id": 20, "flags": 3}],
                        "scriptState": {"variables": [{"index": 1, "kind": "numeric", "value": 7.5}]},
                    },
                }],
            }))
            output = root / "quest-state.json"
            result = compiler.compile_state(semantic, overlay, output)
            self.assertEqual("pass", result["status"])
            state = result["quests"]["0x00000100"]
            self.assertEqual(0x23, state["flags"])
            self.assertEqual(10, state["currentStage"])
            self.assertTrue(state["stageDone"]["10"])
            self.assertEqual(3, state["objectives"]["20"])
            self.assertEqual(7.5, state["variables"]["1"])
            self.assertNotIn("2", state["variables"])
            self.assertEqual(1, result["counts"]["referenceLocalsExcluded"])


if __name__ == "__main__":
    unittest.main()
