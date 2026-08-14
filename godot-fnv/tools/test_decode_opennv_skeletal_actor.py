import struct
import unittest

from decode_opennv_skeletal_actor import DecodeError, decode_bytes


def string(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return struct.pack("<I", len(encoded)) + encoded


def matrix() -> bytes:
    return struct.pack("<16f", 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)


def fixture() -> bytes:
    data = bytearray(b"ONVSKEL1" + struct.pack("<II", 1, 1))
    data += string("Body") + string("Bip01") + string("textures/body.dds")
    data += struct.pack("<III", 3, 3, 1) + matrix() + matrix()
    data += struct.pack("<24f", *([0.0] * 24))
    data += struct.pack("<3I", 0, 1, 2)
    data += string("Bip01") + struct.pack("<i", -1) + matrix() + matrix() + matrix()
    for _ in range(3):
        data += struct.pack("<HHf", 1, 0, 1.0)
    return bytes(data)


def fixture_v3() -> bytes:
    data = bytearray(b"ONVSKEL3" + struct.pack("<II", 3, 0))
    data += struct.pack("<I", 1)
    data += string("Bip01") + struct.pack("<i", -1) + matrix() + matrix()
    data += struct.pack("<I", 1)
    data += string("PCloud02Smoke-Emitter") + string("Bip01") + matrix() + matrix()
    return bytes(data)


class DecoderTests(unittest.TestCase):
    def test_valid_payload(self):
        result = decode_bytes(fixture())
        self.assertEqual(result["surface_count"], 1)
        self.assertEqual(result["totals"]["vertices"], 3)
        self.assertEqual(result["totals"]["influences"], 3)
        self.assertEqual(result["surfaces"][0]["bone_names"], ["Bip01"])

    def test_bad_magic(self):
        with self.assertRaises(DecodeError):
            decode_bytes(b"BADMAGIC" + fixture()[8:])

    def test_v3_auxiliary_transform_hierarchy(self):
        result = decode_bytes(fixture_v3())
        self.assertEqual(3, result["format_version"])
        self.assertEqual(1, result["auxiliary_node_count"])
        self.assertEqual("Bip01", result["auxiliary_nodes"][0]["parent"])

    def test_truncation(self):
        with self.assertRaises(DecodeError):
            decode_bytes(fixture()[:-1])

    def test_trailing_bytes(self):
        with self.assertRaises(DecodeError):
            decode_bytes(fixture() + b"x")

    def test_bad_index(self):
        data = bytearray(fixture())
        # Header/strings/counts/matrices/three packed vertices.
        index_offset = 16 + (4 + 4) + (4 + 5) + (4 + 17) + 12 + 128 + 96
        struct.pack_into("<I", data, index_offset, 3)
        with self.assertRaises(DecodeError):
            decode_bytes(bytes(data))


if __name__ == "__main__":
    unittest.main()
