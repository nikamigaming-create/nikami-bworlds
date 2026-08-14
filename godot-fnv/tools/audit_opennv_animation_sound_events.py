#!/usr/bin/env python3
"""Require every promoted ONVANIM sound text key to resolve to loadable audio."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from decode_opennv_animation import decode_bytes


def resource_path(project_root: Path, value: str) -> Path:
    if not value.startswith("res://"):
        raise ValueError(f"animation path is not a Godot resource: {value}")
    return project_root / value.removeprefix("res://")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--actor-manifest", type=Path, required=True)
    parser.add_argument("--audio-index", type=Path, required=True)
    parser.add_argument("--animation", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    manifest = json.loads(args.actor_manifest.read_text(encoding="utf-8"))
    audio = json.loads(args.audio_index.read_text(encoding="utf-8"))
    animations = {
        str(actor.get("animation_idle", ""))
        for actor in manifest.get("actors", []) if actor.get("animation_idle")
    }
    animations.update(args.animation)
    sound_ids = audio.get("soundEditorIds", {})
    aliases = audio.get("animationSoundAliases", {})
    sounds = audio.get("sounds", {})
    rows = []
    unresolved = []
    event_count = 0
    unique_events: set[str] = set()
    for resource in sorted(animations):
        path = resource_path(project_root, resource)
        payload_bytes = path.read_bytes()
        payload = decode_bytes(payload_bytes)
        events = sorted({
            str(key.get("text", "")).strip().casefold().removeprefix("sound:").strip()
            for key in payload.get("text_keys", [])
            if str(key.get("text", "")).strip().casefold().startswith("sound:")
        })
        event_count += sum(
            str(key.get("text", "")).strip().casefold().startswith("sound:")
            for key in payload.get("text_keys", [])
        )
        unique_events.update(events)
        resolved = []
        for event in events:
            form_id = str(aliases.get(event, sound_ids.get(event, "")))
            record = sounds.get(form_id, {})
            ok = bool(form_id and record.get("files"))
            resolved.append({"event": event, "formId": form_id, "loadable": ok})
            if not ok:
                unresolved.append({"animation": resource, "event": event})
        rows.append({
            "animation": resource,
            "sha256": hashlib.sha256(payload_bytes).hexdigest(),
            "soundEvents": resolved,
        })
    result = {
        "schema": "opennv-animation-sound-event-audit/v1",
        "status": "pass" if not unresolved else "fail",
        "counts": {
            "animationPayloads": len(animations),
            "soundEventKeys": event_count,
            "uniqueSoundEvents": len(unique_events),
            "unresolvedSoundEvents": len(unresolved),
        },
        "animations": rows,
        "unresolved": unresolved,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("OPENNV_ANIMATION_SOUND_EVENTS " + json.dumps(result["counts"], sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
