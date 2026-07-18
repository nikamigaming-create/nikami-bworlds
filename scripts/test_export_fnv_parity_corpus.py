#!/usr/bin/env python3
"""Focused synthetic contracts for export_fnv_parity_corpus.py."""

from __future__ import annotations

import importlib.util
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("export_fnv_parity_corpus.py")
SPEC = importlib.util.spec_from_file_location("export_fnv_parity_corpus", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CORPUS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CORPUS
SPEC.loader.exec_module(CORPUS)


def subrecord(name: str, payload: bytes = b"") -> bytes:
    return name.encode("ascii") + struct.pack("<H", len(payload)) + payload


def record(rtype: str, form_id: int, payload: bytes = b"", flags: int = 0) -> bytes:
    return (
        rtype.encode("ascii")
        + struct.pack("<III", len(payload), flags, form_id)
        + struct.pack("<IHH", 0, 0, 0)
        + payload
    )


def group(label: str, records: list[bytes]) -> bytes:
    payload = b"".join(records)
    return (
        b"GRUP"
        + struct.pack("<I", 24 + len(payload))
        + label.encode("ascii")
        + struct.pack("<IHHHH", 0, 0, 0, 0, 0)
        + payload
    )


def plugin(path: Path, masters: list[str], records: list[bytes]) -> None:
    header_payload = subrecord("HEDR", struct.pack("<fII", 1.34, len(records), 0x800))
    for master in masters:
        header_payload += subrecord("MAST", master.encode("ascii") + b"\0") + subrecord(
            "DATA", struct.pack("<Q", 0)
        )
    path.write_bytes(record("TES4", 0, header_payload) + group("TEST", records))


class CorpusContract(unittest.TestCase):
    def test_master_overrides_deletes_and_feature_denominators(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / "FalloutNV.esm"
            dlc = root / "DeadMoney.esm"
            helper = root / "FNVR.esp"

            base_records = [
                record("CONT", 0x00000100, subrecord("CNTO", struct.pack("<Ii", 0x20, 6))),
                record("REFR", 0x00000200, subrecord("NAME", struct.pack("<I", 0x100))),
                record(
                    "INFO",
                    0x00000300,
                    subrecord("TRDT") + subrecord("NAM1", b"one\0") + subrecord("TRDT")
                    + subrecord("NAM1", b"two\0") + subrecord("CTDA", bytes(20)),
                ),
                record(
                    "QUST",
                    0x00000400,
                    subrecord("INDX", struct.pack("<h", 10)) + subrecord("QSDT", b"\0")
                    + subrecord("QOBJ", struct.pack("<i", 1)) + subrecord("QSTA", bytes(8))
                    + subrecord("SCRI", struct.pack("<I", 0xB00)),
                ),
                record(
                    "ACTI",
                    0x00000500,
                    subrecord("EDID", b"WorkBench\0")
                    + subrecord("RNAM", struct.pack("<I", 0x21)),
                ),
                record(
                    "REFR",
                    0x00000600,
                    subrecord("NAME", struct.pack("<I", 0x500)) + subrecord("XRDO", bytes(16)),
                ),
                record(
                    "REFR", 0x00000700, subrecord("NAME", struct.pack("<I", 0x10)) + subrecord("XMRK")
                ),
                record("CELL", 0x00000800, subrecord("DATA", b"\1")),
                record("TERM", 0x00000900, subrecord("ITXT", b"A\0") + subrecord("ITXT", b"B\0")),
                record("REFR", 0x00000A00, subrecord("NAME", struct.pack("<I", 0x900))),
                record("SCPT", 0x00000B00),
                record("RCPE", 0x00000C00),
                record("RCCT", 0x00000D00),
                record("FURN", 0x00000E00, subrecord("EDID", b"WorkbenchCrafting\0")),
                record("REFR", 0x00000F00, subrecord("NAME", struct.pack("<I", 0xE00))),
                record("DOOR", 0x00001100),
                record(
                    "REFR",
                    0x00001200,
                    subrecord("NAME", struct.pack("<I", 0x1100)) + subrecord("XTEL", bytes(28)),
                ),
                record("NPC_", 0x00001300),
                record("ACHR", 0x00001400, subrecord("NAME", struct.pack("<I", 0x1300))),
            ]
            plugin(base, [], base_records)

            # Local index 0 means FalloutNV.esm; local index 1 means DeadMoney.esm.
            plugin(
                dlc,
                ["FalloutNV.esm"],
                [
                    record("CONT", 0x00000100, flags=CORPUS.REC_DELETED),
                    record("TERM", 0x01000100, subrecord("ITXT", b"DLC\0")),
                ],
            )
            plugin(
                helper,
                ["FalloutNV.esm"],
                [
                    record("ACTI", 0x00000500, flags=CORPUS.REC_DELETED),
                    record("TERM", 0x01000200, subrecord("ITXT", b"helper\0")),
                ],
            )

            report = CORPUS.build_report([base, dlc, helper])
            official = report["corpora"]["official"]
            effective = report["corpora"]["effectiveWithFnvr"]
            helper_layer = report["corpora"]["fnvrLayer"]

            self.assertEqual(official["records"], {
                "physical": 21,
                "winning": 20,
                "live": 19,
                "deletedWinners": 1,
                "unresolvablePhysicalRecords": 0,
                "overriddenPhysicalRecords": 1,
            })
            self.assertEqual(effective["records"], {
                "physical": 23,
                "winning": 21,
                "live": 19,
                "deletedWinners": 2,
                "unresolvablePhysicalRecords": 0,
                "overriddenPhysicalRecords": 2,
            })
            self.assertEqual(
                helper_layer["layerRelationship"], {"overridesOfficial": 1, "newRecords": 1}
            )

            features = official["features"]
            self.assertEqual(features["containers"]["baseRecords"], 0)
            self.assertEqual(features["dialogue"]["responsesTRDT"], 2)
            self.assertEqual(features["dialogue"]["multiResponseInfos"], 1)
            self.assertEqual(features["quests"]["stagesINDX"], 1)
            self.assertEqual(features["scripts"]["attachmentsSCRI"], 1)
            self.assertEqual(features["terminals"]["menuItemsITXT"], 3)
            self.assertEqual(features["craftingCandidates"]["candidateBaseRecords"], 1)
            self.assertEqual(features["craftingCandidates"]["placedCandidateRefs"], 1)
            self.assertEqual(features["doors"]["teleportRefsXTEL"], 1)
            self.assertEqual(features["mapMarkers"]["placedRefsXMRK"], 1)
            self.assertEqual(features["actors"]["placedRefs"], 1)

    def test_unresolvable_retail_form_stays_physical_and_bad_checksum_recovers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / "FalloutNV.esm"
            gra = root / "GunRunnersArsenal.esm"

            unpacked = subrecord("TRDT")
            packed = bytearray(zlib.compress(unpacked))
            packed[-1] ^= 0x01  # Preserve the deflate stream but invalidate Adler-32.
            compressed_payload = struct.pack("<I", len(unpacked)) + bytes(packed)
            plugin(
                base,
                [],
                [record("INFO", 0x00000100, compressed_payload, flags=CORPUS.REC_COMPRESSED)],
            )
            plugin(
                gra,
                ["FalloutNV.esm"],
                [
                    record(
                        "REFR",
                        0x02000801,
                        subrecord("NAME", struct.pack("<I", 0x02000800)),
                    )
                ],
            )

            base_offset = base.read_bytes().find(b"INFO")
            gra_offset = gra.read_bytes().find(b"REFR")
            synthetic_zlib_allowlist = frozenset(
                {
                    (
                        CORPUS._sha256_file(base),
                        base_offset,
                        "INFO",
                        0x00000100,
                    )
                }
            )
            synthetic_form_allowlist = frozenset(
                {
                    (CORPUS._sha256_file(gra), gra_offset, "REFR", 0x02000801),
                    (CORPUS._sha256_file(gra), gra_offset, "REFR.NAME", 0x02000800),
                }
            )
            with mock.patch.object(
                CORPUS,
                "ALLOWED_ZLIB_CHECKSUM_RECOVERIES",
                synthetic_zlib_allowlist,
            ), mock.patch.object(
                CORPUS,
                "ALLOWED_UNRESOLVABLE_FORM_IDS",
                synthetic_form_allowlist,
            ):
                report = CORPUS.build_report([base, gra])
            official = report["corpora"]["official"]
            self.assertEqual(
                official["records"],
                {
                    "physical": 2,
                    "winning": 1,
                    "live": 1,
                    "deletedWinners": 0,
                    "unresolvablePhysicalRecords": 1,
                    "overriddenPhysicalRecords": 0,
                },
            )
            self.assertEqual(official["features"]["dialogue"]["responsesTRDT"], 1)
            by_name = {plugin["name"]: plugin for plugin in report["plugins"]}
            self.assertEqual(
                by_name["FalloutNV.esm"]["payloadDiagnostics"],
                {"recoveredZlibChecksum:INFO": 1},
            )
            self.assertEqual(
                by_name["GunRunnersArsenal.esm"]["payloadDiagnostics"],
                {
                    "unresolvableRecordFormId:REFR": 1,
                    "unresolvableReferencedFormId:REFR.NAME": 1,
                },
            )

    def test_config_resolves_last_data_root_first(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            low = root / "low"
            high = root / "high"
            low.mkdir()
            high.mkdir()
            (low / "FalloutNV.esm").write_bytes(b"low")
            (high / "FalloutNV.esm").write_bytes(b"high")
            (low / "Update.bsa").write_bytes(b"low archive")
            (high / "Update.bsa").write_bytes(b"high archive")
            config = root / "openmw.cfg"
            config.write_text(
                f"data={low}\ndata={high}\ncontent=FalloutNV.esm\n"
                "fallback-archive=Update.bsa\n",
                encoding="utf-8",
            )
            self.assertEqual(CORPUS.plugin_paths_from_config(config), [(high / "FalloutNV.esm").resolve()])
            self.assertEqual(
                CORPUS.archive_sources_from_config(config),
                [CORPUS.ArchiveSource("Update.bsa", (high / "Update.bsa").resolve())],
            )

    def test_archive_paths_are_normalized_and_last_archive_wins(self) -> None:
        low = CORPUS.ArchiveSource("Low.bsa", Path("low.bsa"))
        high = CORPUS.ArchiveSource("High.bsa", Path("high.bsa"))
        aggregate = CORPUS.aggregate_archive_entries(
            [
                (
                    low,
                    [
                        r"Textures\A.DDS",
                        r"sound\voice\Line.OGG",
                        r"meshes\\shared.NIF",
                        r"Docs\Readme",
                    ],
                ),
                (
                    high,
                    [
                        "textures/a.dds",
                        r"MESHES\SHARED.nif",
                        "interface/Icon.DDS",
                        "sound/voice/Line.ogg",
                    ],
                ),
            ]
        )

        self.assertEqual(aggregate["authoredEntries"], 8)
        self.assertEqual(aggregate["uniqueNormalizedVfsPaths"], 5)
        self.assertEqual(aggregate["duplicateOrOverriddenEntries"], 3)
        self.assertEqual(
            aggregate["extensionCounts"],
            {
                "authored": {"<none>": 1, "dds": 3, "nif": 2, "ogg": 2},
                "winning": {"<none>": 1, "dds": 2, "nif": 1, "ogg": 1},
            },
        )
        self.assertEqual(
            [
                (item["authoredEntries"], item["winningVfsPaths"], item["overriddenEntries"])
                for item in aggregate["perArchive"]
            ],
            [(4, 1, 3), (4, 4, 0)],
        )

    def test_archive_report_records_tool_and_archive_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bsatool = root / "bsatool.exe"
            archive = root / "Update.bsa"
            bsatool.write_bytes(b"fake tool")
            archive.write_bytes(b"fake archive")

            def fake_run(
                _tool: Path,
                arguments: tuple[str, ...],
                accepted_return_codes: tuple[int, ...] = (0,),
            ) -> str:
                if arguments == ("--version",):
                    self.assertEqual(accepted_return_codes, (0, 1))
                    return "BSATool version test\n"
                self.assertEqual(accepted_return_codes, (0,))
                self.assertEqual(arguments, ("list", str(archive)))
                return "Textures\\A.DDS\ntextures/a.dds\nsound/x.ogg\n"

            with mock.patch.object(CORPUS, "_run_bsatool", side_effect=fake_run), mock.patch.object(
                CORPUS, "_sha256_file", return_value="ab" * 32
            ):
                report = CORPUS.build_archive_report(
                    [CORPUS.ArchiveSource("Update.bsa", archive)],
                    bsatool,
                    repo_root=root,
                )

            self.assertEqual(report["authoredEntries"], 3)
            self.assertEqual(report["uniqueNormalizedVfsPaths"], 2)
            self.assertEqual(report["duplicateOrOverriddenEntries"], 1)
            self.assertEqual(report["tool"]["versionOutput"], "BSATool version test")
            self.assertTrue(report["localDiagnostics"]["bsatoolRepoLocal"])
            self.assertEqual(report["tool"]["sha256"], "ab" * 32)
            self.assertEqual(
                report["archives"][0],
                {
                    "order": 0,
                    "name": "Update.bsa",
                    "logicalId": "official-archive:Update.bsa",
                    "bytes": len(b"fake archive"),
                    "sha256": "ab" * 32,
                    "authoredEntries": 3,
                    "winningVfsPaths": 2,
                    "overriddenEntries": 1,
                    "normalizedListingSha256": report["archives"][0][
                        "normalizedListingSha256"
                    ],
                },
            )

    def test_nonallowlisted_checksum_recovery_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "FalloutNV.esm"
            unpacked = subrecord("TRDT")
            packed = bytearray(zlib.compress(unpacked))
            packed[-1] ^= 0x01
            plugin(
                base,
                [],
                [
                    record(
                        "INFO",
                        0x00000100,
                        struct.pack("<I", len(unpacked)) + bytes(packed),
                        flags=CORPUS.REC_COMPRESSED,
                    )
                ],
            )

            with self.assertRaisesRegex(CORPUS.CorpusError, "not in the frozen checksum-recovery allowlist"):
                CORPUS.build_report([base])

    def test_nonallowlisted_malformed_form_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "FalloutNV.esm"
            plugin(base, [], [record("REFR", 0x01000001)])

            with self.assertRaisesRegex(CORPUS.CorpusError, "Invalid local FormID"):
                CORPUS.build_report([base])

    def test_strict_profile_rejects_nonempty_overlay_and_reordered_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official = root / "official"
            overlay = root / "overlay"
            official.mkdir()
            overlay.mkdir()
            (overlay / "unexpected.dds").write_bytes(b"overlay")
            plugin_paths = []
            for name in CORPUS.OFFICIAL_NAMES:
                path = official / name
                path.write_bytes(b"plugin")
                plugin_paths.append(path)
            archives = []
            for name in CORPUS.OFFICIAL_ARCHIVE_NAMES:
                path = official / name
                path.write_bytes(b"archive")
                archives.append(CORPUS.ArchiveSource(name, path))
            sources = CORPUS.OpenMWConfigSources(
                path=root / "openmw.cfg",
                data_roots=(overlay, official),
                data_entries=(("data-local", overlay), ("data", official)),
                content=CORPUS.OFFICIAL_NAMES,
                fallback_archives=CORPUS.OFFICIAL_ARCHIVE_NAMES,
            )

            with self.assertRaisesRegex(CORPUS.CorpusError, "permits only empty data-local"):
                CORPUS.validate_strict_official_inputs(plugin_paths, archives, sources)
            with self.assertRaisesRegex(CORPUS.CorpusError, "exactly these plugins in order"):
                CORPUS.validate_strict_official_inputs(
                    list(reversed(plugin_paths)), archives, None
                )

    def test_canonical_hash_excludes_machine_local_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            left = root / "left"
            right = root / "right"
            left.mkdir()
            right.mkdir()
            plugin(left / "FalloutNV.esm", [], [record("STAT", 0x00000100)])
            plugin(right / "FalloutNV.esm", [], [record("STAT", 0x00000100)])
            for directory in (left, right):
                (directory / "bsatool.exe").write_bytes(b"same tool")
                (directory / "Update.bsa").write_bytes(b"same archive")

            def fake_run(
                _tool: Path,
                arguments: tuple[str, ...],
                accepted_return_codes: tuple[int, ...] = (0,),
            ) -> str:
                if arguments == ("--version",):
                    return "BSATool version test\n"
                return "Textures\\A.DDS\n"

            reports = []
            with mock.patch.object(CORPUS, "_run_bsatool", side_effect=fake_run):
                for directory in (left, right):
                    report = CORPUS.build_report([directory / "FalloutNV.esm"])
                    archive_report = CORPUS.build_archive_report(
                        [
                            CORPUS.ArchiveSource(
                                "Update.bsa", directory / "Update.bsa"
                            )
                        ],
                        directory / "bsatool.exe",
                        repo_root=directory,
                    )
                    CORPUS.attach_archive_report(report, archive_report)
                    reports.append(CORPUS.finalize_report(report))
            left_report, right_report = reports

            self.assertNotEqual(
                left_report["localDiagnostics"]["pluginPaths"],
                right_report["localDiagnostics"]["pluginPaths"],
            )
            self.assertEqual(
                left_report["canonicalReportSha256"],
                right_report["canonicalReportSha256"],
            )
            self.assertNotIn(
                str(root).encode("utf-8"), CORPUS._canonical_report_bytes(left_report)
            )

    def test_pwat_family_is_distinct_from_referenced_watr_union(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "FalloutNV.esm"
            plugin(
                base,
                [],
                [
                    record("WATR", 0x00000100, subrecord("EDID", b"CellWater\0")),
                    record("WATR", 0x00000101, subrecord("EDID", b"DrinkWater\0")),
                    record("PWAT", 0x00000102),
                    record("CELL", 0x00000200, subrecord("XCWT", struct.pack("<I", 0x100))),
                    record(
                        "ACTI",
                        0x00000300,
                        subrecord("EDID", b"DrinkActivator\0")
                        + subrecord("WNAM", struct.pack("<I", 0x101)),
                    ),
                    record("REFR", 0x00000400, subrecord("NAME", struct.pack("<I", 0x300))),
                ],
            )

            report = CORPUS.build_report([base])
            official = report["corpora"]["official"]
            self.assertEqual(official["features"]["water"]["uniqueReferencedTypes"], 2)
            self.assertEqual(CORPUS._live_type(official, "PWAT"), 1)


if __name__ == "__main__":
    unittest.main()
