from __future__ import annotations

import struct
import unittest
from pathlib import Path

from decode_opennv_animation import decode_bytes


ROOT = Path(__file__).resolve().parents[1]
HUMANOID = ROOT / "generated/animations/authored-v1/humanoid-mtidle.onvanim"
SECURITRON = ROOT / "generated/animations/authored-v1/securitron-mtidle.onvanim"


class DecodeOpenNVAnimationTests(unittest.TestCase):
    def test_retail_idle_payloads_are_finite_and_complete(self) -> None:
        for path, expected_tracks, expected_frames in ((HUMANOID, 60, 121), (SECURITRON, 63, 402)):
            payload = decode_bytes(path.read_bytes())
            self.assertEqual(payload["track_count"], expected_tracks)
            self.assertEqual(payload["frame_count"], expected_frames)
            self.assertEqual(payload["sample_rate"], 30.0)
            self.assertEqual(payload["nonfinite_values"], 0)
            self.assertEqual(payload["zero_quaternions"], 0)

    def test_rejects_trailing_data(self) -> None:
        with self.assertRaisesRegex(ValueError, "trailing bytes"):
            decode_bytes(HUMANOID.read_bytes() + b"x")

    def test_rejects_invalid_channel_flags(self) -> None:
        data = bytearray()
        data += b"ONVANIM1"
        data += struct.pack("<IffIII", 1, 30.0, 1.0, 1, 1, 0)
        data += struct.pack("<I", 4) + b"bone" + b"\x80"
        with self.assertRaisesRegex(ValueError, "invalid channel flags"):
            decode_bytes(bytes(data))


if __name__ == "__main__":
    unittest.main()
