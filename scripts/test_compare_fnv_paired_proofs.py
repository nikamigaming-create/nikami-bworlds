#!/usr/bin/env python3
"""Synthetic regression test for compare_fnv_paired_proofs.py."""

from __future__ import annotations

import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

import numpy as np
from PIL import Image

import compare_fnv_paired_proofs as comparator


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def write_image(path: Path, rgb: tuple[int, int, int], mask: np.ndarray) -> None:
    array = np.zeros((*mask.shape, 4), dtype=np.uint8)
    array[mask, :3] = rgb
    array[mask, 3] = 255
    Image.fromarray(array, mode="RGBA").save(path)


def write_mask(path: Path, mask: np.ndarray) -> None:
    Image.fromarray((mask.astype(np.uint8) * 255), mode="L").save(path)


class PairedProofComparatorTest(unittest.TestCase):
    def test_reports_missing_part_alpha_silhouette_and_pixel_defects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fnv-paired-proof-") as temporary:
            root = Path(temporary)
            retail = root / "retail"
            openmw = root / "openmw"
            output = root / "output"
            retail.mkdir()
            openmw.mkdir()

            retail_actor = np.zeros((80, 80), dtype=bool)
            retail_actor[8:74, 22:58] = True
            openmw_actor = retail_actor.copy()
            openmw_actor[8:25, 22:31] = False
            retail_body = np.zeros_like(retail_actor)
            retail_body[28:74, 22:58] = True
            openmw_body = retail_body.copy()
            retail_hair = np.zeros_like(retail_actor)
            retail_hair[8:17, 27:53] = True
            openmw_hair = np.zeros_like(retail_actor)

            for directory, actor, color in (
                (retail, retail_actor, (95, 70, 50)),
                (openmw, openmw_actor, (120, 84, 47)),
            ):
                write_image(directory / "actor.png", color, actor)
                write_mask(directory / "actor-mask.png", actor)
            write_mask(retail / "body-mask.png", retail_body)
            write_mask(openmw / "body-mask.png", openmw_body)
            write_mask(retail / "hair-mask.png", retail_hair)
            write_mask(openmw / "hair-mask.png", openmw_hair)
            write_image(retail / "robot.png", (80, 80, 80), retail_actor)
            write_image(openmw / "robot.png", (80, 80, 80), retail_actor)

            common = {
                "captureId": "synthetic-power-armor::stand-front-full-body",
                "actorId": "synthetic-power-armor",
                "shotKind": "stand-front-full-body",
                "cameraStateId": "camera-1",
                "poseState": "stand",
                "weaponId": "tri-beam",
                "weatherId": "clear",
                "gameTime": 12.0,
                "screenshot": "actor.png",
                "actorMask": "actor-mask.png",
                "partMasks": {
                    "body": "body-mask.png",
                    "hair": "hair-mask.png"
                }
            }
            retail_row = {
                **common,
                "telemetry": {
                    "geometry": {"present": True, "vertexCount": 1000},
                    "faceOverlay": {"overlayApplied": True, "overlayLayerCount": 4},
                    "equipmentSlots": {
                        "body": {"visible": True},
                        "weapon": {"visible": True}
                    },
                    "parts": {
                        "body": {"present": True, "effectiveAlpha": 1.0},
                        "hair": {"present": True, "effectiveAlpha": 1.0},
                        "face": {
                            "present": True,
                            "effectiveAlpha": 1.0,
                            "meanRgb": [100, 70, 50],
                            "meanLuma": 75,
                            "blackPixelPercent": 0
                        },
                        "leftHand": {"present": True, "meanRgb": [102, 72, 51]},
                        "neckCap": {"present": False, "goreCap": True}
                    }
                }
            }
            openmw_row = {
                **common,
                "telemetry": {
                    "geometry": {"present": True, "vertexCount": 800},
                    "faceOverlay": {"overlayApplied": False, "overlayLayerCount": 1},
                    "equipmentSlots": {
                        "body": {"visible": False},
                        "weapon": {"visible": True}
                    },
                    "parts": {
                        "body": {"present": True, "effectiveAlpha": 0.5},
                        "hair": {"present": False, "effectiveAlpha": 1.0},
                        "face": {
                            "present": True,
                            "effectiveAlpha": 0.5,
                            "meanRgb": [10, 10, 10],
                            "meanLuma": 10,
                            "blackPixelPercent": 70
                        },
                        "leftHand": {"present": True, "meanRgb": [220, 180, 50]},
                        "neckCap": {"present": True, "goreCap": True}
                    }
                }
            }
            unmatched_common = {
                "captureId": "synthetic-robot::stand-front-full-body",
                "actorId": "synthetic-robot",
                "shotKind": "stand-front-full-body",
                "screenshot": "robot.png",
                "geometry": {"present": True}
            }
            write_json(retail / "index.json", {"rows": [retail_row, unmatched_common]})
            write_json(openmw / "index.json", {"rows": [openmw_row, unmatched_common]})

            manifest = root / "manifest.json"
            write_json(
                manifest,
                {
                    "schema": comparator.MANIFEST_SCHEMA,
                    "defaults": {
                        "matchedCameraState": True,
                        "matchedStateFields": [
                            "cameraStateId",
                            "poseState",
                            "weaponId",
                            "weatherId",
                            "gameTime"
                        ],
                        "expectedParts": ["body", "hair"]
                    },
                    "actors": [
                        {
                            "actorId": "synthetic-power-armor",
                            "captureId": common["captureId"],
                            "requireFaceOverlayEvidence": True,
                            "requireSkinColorEvidence": True,
                            "skinColorGroups": [
                                {"reference": "face", "peers": ["leftHand"]}
                            ],
                            "expectedSlots": ["body", "weapon"],
                            "actorIntact": True,
                            "goreCapParts": ["neckCap"],
                            "requireGoreCapEvidence": True
                        },
                        {
                            "actorId": "synthetic-robot",
                            "captureId": unmatched_common["captureId"],
                            "matchedCameraState": False,
                            "matchedStateFields": [],
                            "expectedParts": []
                        }
                    ]
                }
            )

            code, report = comparator.run(
                Namespace(
                    manifest=manifest,
                    retail_dir=retail,
                    openmw_dir=openmw,
                    retail_index=None,
                    openmw_index=None,
                    output=output,
                    rows_per_sheet=1,
                    thumbnail_width=180,
                    fail_on_defect=False
                )
            )
            self.assertEqual(code, 0)
            self.assertEqual(report["summary"]["actorCount"], 2)
            self.assertEqual(report["summary"]["pixelMetricsMeasured"], 1)
            first_codes = {item["code"] for item in report["actors"][0]["defects"]}
            self.assertIn("part-missing", first_codes)
            self.assertIn("unexpected-part-transparency", first_codes)
            self.assertIn("silhouette-missing-coverage", first_codes)
            self.assertIn("face-overlay-missing", first_codes)
            self.assertIn("black-head-artifact", first_codes)
            self.assertIn("head-alpha-mismatch", first_codes)
            self.assertIn("skin-part-color-mismatch", first_codes)
            self.assertIn("outfit-slot-missing", first_codes)
            self.assertIn("intact-gore-cap-visible", first_codes)
            self.assertEqual(report["actors"][0]["pixels"]["status"], "measured")
            self.assertEqual(report["actors"][1]["pixels"]["status"], "not-measured")
            self.assertEqual(report["actors"][1]["status"], "unknown")
            self.assertEqual(len(report["artifacts"]["contactSheets"]), 2)
            self.assertTrue((output / "paired-proof-report.json").is_file())
            self.assertTrue((output / "actor-defects.json").is_file())
            self.assertTrue((output / "contact-sheet-001.png").is_file())
            self.assertTrue((output / "contact-sheet-002.png").is_file())
            self.assertTrue((output / "contact-sheet-index.json").is_file())


if __name__ == "__main__":
    unittest.main()
