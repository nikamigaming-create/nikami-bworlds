#!/usr/bin/env python3
"""Resolve authored OpenNV SOUN/MUSC paths against the user's BSA archives."""

from __future__ import annotations

import argparse
import json
import subprocess
from collections import Counter, defaultdict
from pathlib import Path, PureWindowsPath


AUDIO_EXTENSIONS = (".wav", ".ogg", ".mp3")


def _canonical(value: str) -> str:
    return str(PureWindowsPath(value.replace("/", "\\"))).lstrip("\\").casefold()


def _authored_path(value: str, prefix: str) -> str:
    path = _canonical(value)
    return path if path.startswith(prefix + "\\") else prefix + "\\" + path


def _list_archive(bsatool: Path, archive: Path) -> list[str]:
    result = subprocess.run(
        [str(bsatool), "list", str(archive)], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        encoding="utf-8", errors="replace",
    )
    return [_canonical(line.strip()) for line in result.stdout.splitlines() if line.strip()]


def compile_audit(semantic: Path, data_root: Path, bsatool: Path) -> dict:
    payload = json.loads(semantic.read_text(encoding="utf-8"))
    archives = sorted(data_root.glob("*.bsa"), key=lambda path: path.name.casefold())
    file_sources: dict[str, list[str]] = defaultdict(list)
    archive_counts = {}
    for archive in archives:
        rows = _list_archive(bsatool, archive)
        archive_counts[archive.name] = len(rows)
        for row in rows:
            if row.endswith(AUDIO_EXTENSIONS):
                file_sources[row].append(archive.name)
    loose_count = 0
    for root_name in ("Sound", "Music"):
        root = data_root / root_name
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix.casefold() not in AUDIO_EXTENSIONS:
                continue
            relative = _canonical(str(path.relative_to(data_root)))
            file_sources[relative].append("loose:" + str(path.relative_to(data_root)).replace("\\", "/"))
            loose_count += 1
    available = sorted(file_sources)

    def resolve(authored: str) -> list[str]:
        exact = authored.rstrip("\\")
        if exact in file_sources:
            return [exact]
        # FNV represents randomized families as a directory FNAM. The RNAM
        # byte is not a reliable family count; suffix absence is authoritative.
        if PureWindowsPath(exact).suffix.casefold() not in AUDIO_EXTENSIONS:
            prefix = exact + "\\"
            return [row for row in available if row.startswith(prefix)]
        stem = str(PureWindowsPath(exact).with_suffix(""))
        return [stem + ext for ext in AUDIO_EXTENSIONS if stem + ext in file_sources]

    sound_rows = []
    sound_by_id = {}
    for row in payload.get("sounds", []):
        authored_value = str(row.get("soundFile", "")).strip()
        authored = _authored_path(authored_value, "sound") if authored_value else ""
        matches = resolve(authored) if authored else []
        item = {
            "formId": row.get("id"),
            "editorId": row.get("editorId", ""),
            "sourcePlugin": row.get("sourcePlugin", ""),
            "authoredPath": authored,
            "soundRnamByte": int(row.get("soundRnamByte", 0)),
            "files": matches,
            "fileSources": {match: sorted(file_sources[match]) for match in matches},
            "archives": sorted({source for match in matches for source in file_sources[match]}),
            "status": "resolved" if matches else ("no-authored-path" if not authored else "missing"),
            "soundData": row.get("soundData", {}),
        }
        sound_rows.append(item)
        sound_by_id[str(item["formId"])] = item

    music_rows = []
    for row in payload.get("music", []):
        authored_value = str(row.get("musicFile", "")).strip()
        authored = _authored_path(authored_value, "music") if authored_value else ""
        matches = resolve(authored) if authored else []
        music_rows.append({
            "formId": row.get("id"),
            "editorId": row.get("editorId", ""),
            "sourcePlugin": row.get("sourcePlugin", ""),
            "authoredPath": authored,
            "files": matches,
            "fileSources": {match: sorted(file_sources[match]) for match in matches},
            "archives": sorted({source for match in matches for source in file_sources[match]}),
            "status": "resolved" if matches else ("no-authored-path" if not authored else "missing"),
        })

    referenced_ids = []
    for row in payload.get("consumers", []):
        for key in ("loopingSound", "activationSound", "openSound", "closeSound", "loopSound", "pickupSound", "dropSound"):
            if row.get(key):
                referenced_ids.append(str(row[key]))
        referenced_ids.extend(str(entry["sound"]) for entry in row.get("weaponSounds", []) if entry.get("sound"))
    unique_references = sorted(set(referenced_ids), key=lambda value: int(value, 16))
    reference_status = Counter(
        sound_by_id.get(form_id, {}).get("status", "missing-record") for form_id in unique_references
    )
    sound_status = Counter(row["status"] for row in sound_rows)
    music_status = Counter(row["status"] for row in music_rows)
    return {
        "schema": "opennv-sound-asset-audit/v1",
        "status": "pass" if not sound_status["missing"] and not reference_status["missing-record"] else "fail",
        "semanticSource": str(semantic.resolve()).replace("\\", "/"),
        "dataRoot": str(data_root.resolve()).replace("\\", "/"),
        "counts": {
            "archives": len(archives),
            "archiveFiles": sum(archive_counts.values()),
            "audioFiles": len(file_sources),
            "looseAudioFiles": loose_count,
            "sounds": len(sound_rows),
            "soundsResolved": sound_status["resolved"],
            "soundsMissing": sound_status["missing"],
            "soundsWithoutAuthoredPath": sound_status["no-authored-path"],
            "music": len(music_rows),
            "musicResolved": music_status["resolved"],
            "musicMissing": music_status["missing"],
            "uniqueConsumerSoundReferences": len(unique_references),
            "consumerReferencesResolved": reference_status["resolved"],
            "consumerReferencesMissingRecord": reference_status["missing-record"],
            "consumerReferencesMissingAsset": reference_status["missing"],
        },
        "archiveFileCounts": archive_counts,
        "sounds": sound_rows,
        "music": music_rows,
        "consumerReferenceStatus": dict(sorted(reference_status.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--semantic", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--bsatool", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = compile_audit(args.semantic, args.data_root, args.bsatool)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("OPENNV_SOUND_ASSET_AUDIT " + json.dumps(report["counts"], sort_keys=True))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
