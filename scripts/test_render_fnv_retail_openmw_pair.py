#!/usr/bin/env python3
"""Regression tests for the fail-closed Save330 visual-pair candidate gate."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import render_fnv_retail_openmw_pair as pairer


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def evidence(path: Path, **extra: object) -> dict[str, object]:
    value: dict[str, object] = {
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": pairer.sha256_file(path),
    }
    value.update(extra)
    return value


class Save330VisualPairGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="fnv-save330-pair-")
        self.root = Path(self.temporary.name)
        self.save = self.root / "Save330.fos"
        self.save.write_bytes((b"save330-fixture" * 64) + b"!")
        self.save_hash = hashlib.sha256(self.save.read_bytes()).hexdigest()

        self.openmw = self.root / "openmw-frame.png"
        image = Image.new("RGB", (64, 40))
        for y in range(image.height):
            for x in range(image.width):
                image.putpixel((x, y), ((x * 3 + 30) % 256, (y * 5 + 45) % 256, (x + y + 10) % 128))
        image.save(self.openmw)

        self.retail_image = self.root / "retail-reference.png"
        image.save(self.retail_image)
        self.binary = self.root / "openmw.exe"
        self.binary.write_bytes(b"flat-openmw-binary")
        self.config = self.root / "settings.cfg"
        self.config.write_text("[Camera]\nviewing distance = 10000\n", encoding="utf-8")
        self.log = self.root / "openmw.log"
        self.log.write_text("normal Save330 load complete\n", encoding="utf-8")
        self.data_root = self.root / "Data"
        self.data_root.mkdir()

        self.retail_manifest = self.root / "retail-reference.manifest.json"
        write_json(
            self.retail_manifest,
            {
                "schema": pairer.RETAIL_REFERENCE_SCHEMA,
                "status": "fixed",
                "saveSha256": self.save_hash,
                "save": evidence(self.save),
                "image": evidence(self.retail_image, width=64, height=40),
                "camera": {
                    "metadataStatus": "complete",
                    "mode": "first-person",
                    "position": [100.0, 200.0, 300.0],
                    "headingDegrees": 90.0,
                    "fieldOfViewDegrees": 75.0,
                    "viewportCropNormalized": [0.0, 0.0, 1.0, 1.0],
                },
                "scene": {
                    "metadataStatus": "complete",
                    "gameTimeHours": 14.5,
                    "weatherFormId": "0x0011237D7",
                    "visibleAuthoredReferences": ["0x000846EA", "0x0010A1F4"],
                },
                "candidatePolicy": {"eligibleNow": True},
            },
        )

        self.capture_manifest = self.root / "openmw-capture.manifest.json"
        self.capture = {
            "schema": pairer.CAPTURE_SCHEMA,
            "status": "passed",
            "candidateEligible": True,
            "launch": {
                "engine": "OpenMW",
                "mode": "flat",
                "kind": "normal-save330-load",
                "normalLoadGamePath": True,
                "diagnostic": False,
                "bootstrap": False,
                "synthetic": False,
                "stateInjection": False,
                "injectedState": [],
                "arguments": ["--replace", "config", "--load-savegame", str(self.save)],
                "environment": {"OPENMW_DEBUG_LEVEL": "INFO"},
            },
            "inputSave": evidence(
                self.save,
                consumedByRuntime=True,
                normalLoadCompleted=True,
                loadedPlayerFormId="0x00000007",
            ),
            "runtime": {
                "committedSource": True,
                "sourceDirty": False,
                "sourceCommit": "a" * 40,
                "binary": evidence(self.binary),
                "configuration": [evidence(self.config)],
                "contentOrder": pairer.OFFICIAL_CONTENT_ORDER,
                "dataRoots": [str(self.data_root)],
                "log": evidence(self.log),
            },
            "capture": {
                "kind": "normal-gameplay-screenshot",
                "diagnostic": False,
                "screenshot": evidence(self.openmw, width=64, height=40),
                "camera": {
                    "mode": "first-person",
                    "position": [100.5, 200.0, 300.0],
                    "headingDegrees": 90.5,
                    "fieldOfViewDegrees": 75.25,
                    "viewportCropNormalized": [0.0, 0.0, 1.0, 1.0],
                },
                "scene": {
                    "gameTimeHours": 14.52,
                    "weatherFormId": "0x0011237d7",
                    "visibleAuthoredReferences": ["0x0010A1F4", "0x000846EA"],
                },
            },
            "retailReferenceManifest": evidence(self.retail_manifest),
            "matchingTolerances": {
                "positionUnitsMaximum": 1.0,
                "headingDegreesMaximum": 1.0,
                "fieldOfViewDegreesMaximum": 0.5,
                "gameTimeHoursMaximum": 0.05,
            },
            "pairing": {
                "openmwCropPixels": None,
                "fitOpenmw": False,
                "comparisonCropPixels": None,
            },
        }
        write_json(self.capture_manifest, self.capture)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def validate(self) -> dict[str, object]:
        with mock.patch.multiple(
            pairer,
            SAVE330_BYTES=self.save.stat().st_size,
            SAVE330_SHA256=self.save_hash,
            SAVE330_REFERENCE_PNG_SHA256=pairer.sha256_file(self.retail_image),
            SAVE330_SCREENSHOT_WIDTH=64,
            SAVE330_SCREENSHOT_HEIGHT=40,
        ):
            return pairer.validate_candidate_provenance(
                self.capture_manifest,
                self.openmw,
                (64, 40),
                openmw_crop=None,
                fit_openmw=False,
                comparison_crop=None,
            )

    def rewrite_capture(self) -> None:
        write_json(self.capture_manifest, self.capture)

    def test_accepts_exact_normal_flat_first_person_capture_contract(self) -> None:
        result = self.validate()
        self.assertEqual(result["status"], "passed")
        self.assertTrue(result["normalSave330Load"])
        self.assertTrue(result["flatFirstPerson"])
        self.assertEqual(result["cameraAndSceneMatch"]["positionDeltaUnits"], 0.5)

    def test_rejects_bootstrap_even_when_every_file_hash_matches(self) -> None:
        self.capture["launch"]["bootstrap"] = True
        self.rewrite_capture()
        with self.assertRaisesRegex(pairer.ProvenanceError, r"launch\.bootstrap must be false"):
            self.validate()

    def test_rejects_forbidden_start_argument(self) -> None:
        self.capture["launch"]["arguments"].append("--start=Goodsprings")
        self.rewrite_capture()
        with self.assertRaisesRegex(pairer.ProvenanceError, "forbidden argument"):
            self.validate()

    def test_rejects_camera_mismatch(self) -> None:
        self.capture["capture"]["camera"]["headingDegrees"] = 105.0
        self.rewrite_capture()
        with self.assertRaisesRegex(pairer.ProvenanceError, "camera heading"):
            self.validate()

    def test_rejects_different_right_hand_screenshot(self) -> None:
        self.capture["capture"]["screenshot"]["sha256"] = "0" * 64
        self.rewrite_capture()
        with self.assertRaisesRegex(pairer.ProvenanceError, "sha256 differs"):
            self.validate()

    def test_rejects_black_and_white_pixels(self) -> None:
        grayscale = Image.new("RGB", (64, 40))
        for y in range(grayscale.height):
            for x in range(grayscale.width):
                level = (x * 4 + y * 2) % 256
                grayscale.putpixel((x, y), (level, level, level))
        quality = pairer.analyze_image_quality(grayscale)
        self.assertEqual(quality["status"], "rejected")
        self.assertIn("monochrome-or-black-white", quality["reasons"])

    def test_repository_retail_oracle_remains_fail_closed_until_metadata_exists(self) -> None:
        oracle = json.loads(
            (Path(__file__).resolve().parents[1]
             / "oracles/fnv_save330_visual/retail-save330-reference.manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(oracle["camera"]["metadataStatus"], "incomplete")
        self.assertEqual(oracle["scene"]["metadataStatus"], "incomplete")
        self.assertFalse(oracle["candidatePolicy"]["eligibleNow"])

    def test_rejected_pair_manifest_records_failed_candidate_gate(self) -> None:
        retail_bgra = self.root / "retail.bgra"
        with Image.open(self.retail_image) as retail:
            retail_bgra.write_bytes(retail.convert("RGBA").tobytes("raw", "BGRA"))
        output = self.root / "rejected-pair.png"
        manifest = self.root / "rejected-pair.manifest.json"
        argv = [
            "render_fnv_retail_openmw_pair.py",
            "--retail-bgra",
            str(retail_bgra),
            "--openmw",
            str(self.openmw),
            "--width",
            "64",
            "--height",
            "40",
            "--output",
            str(output),
            "--manifest",
            str(manifest),
            "--status",
            "rejected",
        ]
        with mock.patch.object(sys, "argv", argv):
            self.assertEqual(pairer.main(), 0)
        result = json.loads(manifest.read_text(encoding="utf-8"))
        self.assertEqual(result["schema"], pairer.PAIR_SCHEMA)
        self.assertFalse(result["candidateGate"]["eligible"])
        self.assertFalse(result["candidateGate"]["normalSave330Provenance"])
        self.assertFalse(result["accepted"])


if __name__ == "__main__":
    unittest.main()
