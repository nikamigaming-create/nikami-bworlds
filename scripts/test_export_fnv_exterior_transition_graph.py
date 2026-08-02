#!/usr/bin/env python3
"""Focused synthetic contracts for export_fnv_exterior_transition_graph.py."""

from __future__ import annotations

import importlib.util
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("export_fnv_exterior_transition_graph.py")
SPEC = importlib.util.spec_from_file_location("export_fnv_exterior_transition_graph", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GRAPH = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GRAPH
SPEC.loader.exec_module(GRAPH)


def subrecord(name: str, payload: bytes = b"") -> bytes:
    return name.encode("ascii") + struct.pack("<H", len(payload)) + payload


def record(rtype: str, form_id: int, payload: bytes = b"", flags: int = 0) -> bytes:
    return (
        rtype.encode("ascii")
        + struct.pack("<III", len(payload), flags, form_id)
        + struct.pack("<IHH", 0, 0, 0)
        + payload
    )


def group(label: bytes, group_type: int, records: list[bytes]) -> bytes:
    assert len(label) == 4
    payload = b"".join(records)
    return b"GRUP" + struct.pack("<I", 24 + len(payload)) + label + struct.pack(
        "<IHHHH", group_type, 0, 0, 0, 0
    ) + payload


def form_label(value: int) -> bytes:
    return struct.pack("<I", value)


def plugin(path: Path, masters: list[str], records: list[bytes]) -> None:
    header_payload = subrecord("HEDR", struct.pack("<fII", 1.34, len(records), 0x800))
    for master in masters:
        header_payload += subrecord("MAST", master.encode("ascii") + b"\0")
        header_payload += subrecord("DATA", struct.pack("<Q", 0))
    path.write_bytes(record("TES4", 0, header_payload) + group(b"TEST", 0, records))


def transform(x: float, y: float, z: float) -> bytes:
    return struct.pack("<ffffff", x, y, z, 0.0, 0.0, 0.0)


def xtel(destination: int, x: float, y: float, z: float) -> bytes:
    return struct.pack("<IffffffI", destination, x, y, z, 0.0, 0.0, 0.0, 0)


def exterior_cell(form: int, x: int, y: int) -> bytes:
    return record(
        "CELL",
        form,
        subrecord("DATA", b"\0") + subrecord("XCLC", struct.pack("<ii", x, y)),
    )


class ExteriorTransitionGraphContract(unittest.TestCase):
    def _base_plugin(self, root: Path) -> Path:
        base = root / "FalloutNV.esm"
        door_script = 0x00000400
        source_script = 0x00000401
        door = record(
            "DOOR",
            0x00000300,
            subrecord("EDID", b"OpenAirGate\0")
            + subrecord("FULL", b"Open Air Gate\0")
            + subrecord("MODL", b"meshes\\gates\\openair.nif\0")
            + subrecord("SCRI", struct.pack("<I", door_script)),
        )
        source = record(
            "REFR",
            0x00000500,
            subrecord("NAME", struct.pack("<I", 0x00000300))
            + subrecord("DATA", transform(10.0, 20.0, 30.0))
            + subrecord("XTEL", xtel(0x00000501, 100.0, 200.0, 300.0))
            + subrecord("XLOC", struct.pack("<bBHI", 50, 3, 0, 0))
            + subrecord("XESP", struct.pack("<II", 0x00000600, 1))
            + subrecord("SCRI", struct.pack("<I", source_script)),
        )
        destination = record(
            "REFR",
            0x00000501,
            subrecord("NAME", struct.pack("<I", 0x00000300))
            + subrecord("DATA", transform(100.0, 200.0, 300.0))
            + subrecord("XTEL", xtel(0x00000500, 10.0, 20.0, 30.0)),
        )
        world_one = record("WRLD", 0x00000100, subrecord("EDID", b"WorldOne\0"))
        world_two = record("WRLD", 0x00000101, subrecord("EDID", b"WorldTwo\0"))
        world_one_children = group(
            form_label(0x00000100),
            1,
            [
                exterior_cell(0x00000200, 4, 8),
                group(form_label(0x00000200), 6, [source]),
            ],
        )
        world_two_children = group(
            form_label(0x00000101),
            1,
            [
                exterior_cell(0x00000201, 9, 12),
                group(form_label(0x00000201), 6, [destination]),
            ],
        )
        plugin(
            base,
            [],
            [
                record("SCPT", door_script),
                record("SCPT", source_script),
                door,
                world_one,
                world_one_children,
                world_two,
                world_two_children,
            ],
        )
        return base

    def test_resolves_directed_edges_context_and_reverse_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = self._base_plugin(Path(temporary))
            graph = GRAPH.build_transition_graph([base])

            self.assertEqual(graph["schema"], GRAPH.GRAPH_SCHEMA)
            self.assertEqual(graph["counts"]["xtelEdges"], 2)
            self.assertEqual(graph["counts"]["resolvedEdges"], 2)
            self.assertEqual(graph["unresolvedEdges"], [])
            self.assertEqual(graph["counts"]["exactReversePairs"], 1)

            edges = {edge["edgeId"]: edge for edge in graph["edges"]}
            source = edges["xtel:0x00000500"]
            self.assertEqual(source["source"]["cell"]["formId"], "0x00000200")
            self.assertTrue(source["source"]["cell"]["isExterior"])
            self.assertEqual(source["source"]["world"]["formId"], "0x00000100")
            self.assertEqual(source["destination"]["ref"]["formId"], "0x00000501")
            self.assertEqual(source["destination"]["world"]["formId"], "0x00000101")
            self.assertEqual(source["reverseEdgeId"], "xtel:0x00000501")
            self.assertEqual(source["reverseResolution"], "exact")
            self.assertEqual(source["source"]["base"]["type"], "DOOR")
            self.assertEqual(source["source"]["base"]["model"], "meshes\\gates\\openair.nif")
            self.assertEqual(source["source"]["lock"]["level"], 50)
            self.assertEqual(source["source"]["enableParent"], "0x00000600")
            self.assertEqual(source["source"]["script"], "0x00000401")
            self.assertFalse(source["classificationHints"]["sameWorldspace"])
            self.assertTrue(source["classificationHints"]["sourceExterior"])
            self.assertTrue(source["classificationHints"]["destinationExterior"])

            policy = GRAPH.build_policy_template(graph)
            self.assertEqual(policy["schema"], GRAPH.POLICY_SCHEMA)
            self.assertEqual(policy["edges"], [])
            self.assertEqual(len(policy["graphDefaults"]), 1)
            self.assertEqual(policy["graphDefaults"][0]["classification"], "unreviewed")
            self.assertEqual(policy["generatedFrom"]["graphSha256"], graph["canonicalGraphSha256"])

    def test_later_override_wins_and_unresolved_destination_is_retained(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = self._base_plugin(root)
            dlc = root / "DeadMoney.esm"
            override = record(
                "REFR",
                0x00000500,
                subrecord("NAME", struct.pack("<I", 0x00000300))
                + subrecord("XTEL", xtel(0x00000999, 1.0, 2.0, 3.0)),
            )
            plugin(
                dlc,
                ["FalloutNV.esm"],
                [
                    group(
                        form_label(0x00000100),
                        1,
                        [group(form_label(0x00000200), 6, [override])],
                    )
                ],
            )

            graph = GRAPH.build_transition_graph([base, dlc])
            source = next(edge for edge in graph["edges"] if edge["edgeId"] == "xtel:0x00000500")
            self.assertEqual(source["provenance"]["plugin"], "DeadMoney.esm")
            self.assertEqual(source["destination"]["referenceFormId"], "0x00000999")
            self.assertEqual(source["resolution"]["status"], "unresolved")
            self.assertIn("destination-reference-not-found", source["resolution"]["issues"])
            self.assertIn(
                "xtel:0x00000500",
                {entry["edgeId"] for entry in graph["unresolvedEdges"]},
            )

    def test_canonical_selection_records_but_does_not_mutate_profile_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / "Data"
            data.mkdir()
            for name in GRAPH.corpus.OFFICIAL_NAMES:
                (data / name).write_bytes(b"placeholder")
            configured = list(reversed(GRAPH.corpus.OFFICIAL_NAMES))
            config = root / "openmw.cfg"
            config.write_text(
                "data=Data\n" + "".join(f"content={name}\n" for name in configured),
                encoding="utf-8",
            )

            paths, metadata = GRAPH.canonical_official_paths_from_config(config)

            self.assertEqual([path.name for path in paths], list(GRAPH.corpus.OFFICIAL_NAMES))
            self.assertEqual(metadata["configuredContentOrder"], configured)
            self.assertFalse(metadata["configuredContentOrderMatchesFrozen"])


if __name__ == "__main__":
    unittest.main()
