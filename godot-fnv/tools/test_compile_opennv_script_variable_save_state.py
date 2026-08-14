from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("compile_opennv_script_variable_save_state.py")
SPEC = importlib.util.spec_from_file_location("compile_opennv_script_variable_save_state", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ScriptVariableSaveStateTests(unittest.TestCase):
    def test_native_zero_default_and_saved_numeric_override(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index_path = root / "index.json"
            overlay_path = root / "overlay.json"
            index_path.write_text(json.dumps({
                "schema": "opennv-script-variable-index/v1",
                "counts": {"function53ExplicitReferenceRows": 2},
                "function53": [
                    {"targetMode": "reference", "definitionResolved": True, "targetReference": "0x00000010", "localIndex": 1, "script": "0x00000100", "localName": "State"},
                    {"targetMode": "reference", "definitionResolved": True, "targetReference": "0x00000020", "localIndex": 2, "script": "0x00000200", "localName": "Timer"},
                ],
            }), encoding="utf-8")
            overlay_path.write_text(json.dumps({
                "schema": "opennv-fos-changeform-index/v1", "source": {"sha256": "save"},
                "changeForms": [{
                    "refId": {"resolvedFormId": "0x00000020"}, "changeFlags": "0x80000000",
                    "changedExtraState": {"fullyDecoded": True},
                    "scriptState": {"script": {"resolvedFormId": "0x00000200"}, "variables": [
                        {"index": 2, "kind": "numeric", "value": 4.5},
                    ]},
                }],
            }), encoding="utf-8")
            result = MODULE.compile_state(index_path, overlay_path, root / "result.json")
            self.assertEqual("pass", result["status"])
            self.assertEqual(0.0, result["values"]["0x00000010:1"]["value"])
            self.assertEqual(4.5, result["values"]["0x00000020:2"]["value"])
            self.assertEqual(2, result["counts"]["operationalResolvedExplicitRows"])
            self.assertEqual(1, result["counts"]["explicitSavedValueRows"])
            self.assertEqual(1, result["counts"]["inferredZeroRows"])

    def test_changed_extra_without_decoded_script_stays_unresolved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index_path, overlay_path = root / "index.json", root / "overlay.json"
            index_path.write_text(json.dumps({
                "schema": "opennv-script-variable-index/v1",
                "counts": {"function53ExplicitReferenceRows": 1},
                "function53": [{"targetMode": "reference", "definitionResolved": True,
                    "targetReference": "0x00000020", "localIndex": 2,
                    "script": "0x00000200", "localName": "Timer"}],
            }), encoding="utf-8")
            overlay_path.write_text(json.dumps({
                "schema": "opennv-fos-changeform-index/v1", "source": {"sha256": "save"},
                "changeForms": [{"refId": {"resolvedFormId": "0x00000020"},
                    "type": "ACHR", "changeFlags": "0x00000800", "scriptState": None}],
            }), encoding="utf-8")
            result = MODULE.compile_state(index_path, overlay_path, root / "result.json")
            self.assertEqual("partial", result["status"])
            self.assertEqual(1, result["counts"]["unresolvedExplicitRows"])
            self.assertNotIn("0x00000020:2", result["values"])


if __name__ == "__main__":
    unittest.main()
