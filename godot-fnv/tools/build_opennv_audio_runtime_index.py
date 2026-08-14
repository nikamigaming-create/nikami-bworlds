#!/usr/bin/env python3
"""Compile audited FNV audio assets into absolute, directly loadable Godot paths."""

from __future__ import annotations

import argparse
import json
from pathlib import Path, PureWindowsPath


ARCHIVE_PRECEDENCE = {
    name.casefold(): index for index, name in enumerate((
        "Fallout - Sound.bsa",
        "Update.bsa",
        "DeadMoney - Sounds.bsa",
        "HonestHearts - Sounds.bsa",
        "OldWorldBlues - Sounds.bsa",
        "LonesomeRoad - Sounds.bsa",
        "GunRunnersArsenal - Sounds.bsa",
    ))
}

# Retail KF text keys use short animation event names rather than the SOUN
# editor ID. Keep this as a small, validated compiler contract: an alias is
# emitted only when its target resolves to an authored, loadable SOUN record.
ANIMATION_SOUND_EDITOR_ID_ALIASES = {
    "npchumanchew": "npchumaneatingfoodchewyanim",
    # The retail eat KF emits this event but the ten-plugin load order has no
    # SOUN editor ID or separate swallow asset. Route it to the same authored
    # eating-event SOUN family and retain the alias explicitly in the index.
    "npchumanswallow": "npchumaneatingfoodchewyanim",
}


def _native_relative(value: str) -> Path:
    return Path(*PureWindowsPath(value).parts)


def _source_path(source: str, authored_file: str, data_root: Path, archive_root: Path) -> Path:
    if source.startswith("loose:"):
        return data_root / _native_relative(source.removeprefix("loose:"))
    return archive_root / Path(source).stem / _native_relative(authored_file)


def _choose(sources: list[str]) -> str:
    loose = [source for source in sources if source.startswith("loose:")]
    if loose:
        return sorted(loose, key=str.casefold)[-1]
    return max(sources, key=lambda source: ARCHIVE_PRECEDENCE.get(source.casefold(), -1))


def compile_index(audit: dict, data_root: Path, archive_root: Path) -> dict:
    missing_extracted = []

    def compile_rows(rows: list[dict]) -> dict[str, dict]:
        result = {}
        for row in rows:
            files = []
            provenance = []
            for authored_file in row.get("files", []):
                sources = row.get("fileSources", {}).get(authored_file, [])
                if not sources:
                    continue
                source = _choose(sources)
                path = _source_path(source, authored_file, data_root, archive_root).resolve()
                if not path.is_file():
                    missing_extracted.append({
                        "formId": row.get("formId"), "file": authored_file,
                        "source": source, "expectedPath": str(path).replace("\\", "/"),
                    })
                    continue
                files.append(str(path).replace("\\", "/"))
                provenance.append({"file": authored_file, "source": source})
            result[str(row.get("formId"))] = {
                "editorId": row.get("editorId", ""),
                "files": files,
                "provenance": provenance,
                "soundData": row.get("soundData", {}),
                "assetStatus": row.get("status", "missing"),
            }
        return result

    sounds = compile_rows(audit.get("sounds", []))
    music = compile_rows(audit.get("music", []))
    sound_editor_ids = {
        row["editorId"].casefold(): form_id
        for form_id, row in sounds.items() if row.get("editorId")
    }
    music_editor_ids = {
        row["editorId"].casefold(): form_id
        for form_id, row in music.items() if row.get("editorId")
    }
    animation_sound_aliases = {}
    missing_animation_sound_aliases = []
    for alias, target_editor_id in ANIMATION_SOUND_EDITOR_ID_ALIASES.items():
        target_form_id = sound_editor_ids.get(target_editor_id)
        target_record = sounds.get(str(target_form_id), {})
        if not target_form_id or not target_record.get("files"):
            missing_animation_sound_aliases.append({
                "alias": alias, "targetEditorId": target_editor_id,
            })
            continue
        animation_sound_aliases[alias] = str(target_form_id)
    counts = {
        "sounds": len(sounds),
        "soundsLoadable": sum(bool(row["files"]) for row in sounds.values()),
        "soundFilesLoadable": sum(len(row["files"]) for row in sounds.values()),
        "music": len(music),
        "musicLoadable": sum(bool(row["files"]) for row in music.values()),
        "musicFilesLoadable": sum(len(row["files"]) for row in music.values()),
        "missingExtractedFiles": len(missing_extracted),
        "animationSoundAliases": len(animation_sound_aliases),
        "missingAnimationSoundAliases": len(missing_animation_sound_aliases),
    }
    return {
        "schema": "opennv-audio-runtime-index/v1",
        "status": "pass" if not missing_extracted and not missing_animation_sound_aliases else "fail",
        "dataRoot": str(data_root.resolve()).replace("\\", "/"),
        "archiveRoot": str(archive_root.resolve()).replace("\\", "/"),
        "counts": counts,
        "sounds": sounds,
        "soundEditorIds": sound_editor_ids,
        "animationSoundAliases": animation_sound_aliases,
        "music": music,
        "musicEditorIds": music_editor_ids,
        "missingExtractedFiles": missing_extracted,
        "missingAnimationSoundAliases": missing_animation_sound_aliases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--archive-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    audit = json.loads(args.audit.read_text(encoding="utf-8"))
    result = compile_index(audit, args.data_root, args.archive_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(",", ":")) + "\n", encoding="utf-8")
    print("OPENNV_AUDIO_RUNTIME_INDEX " + json.dumps(result["counts"], sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
