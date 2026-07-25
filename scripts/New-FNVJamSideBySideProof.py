#!/usr/bin/env python3
"""Build a telemetry-backed retail/OpenMW JAM comparison without app control."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


SCENES = [
    (1, 920, "JDC.dynamic-crosshair", "weapon-ready-idle", "JDC IDLE", "JIP LN"),
    (2, 1060, "JDC.dynamic-crosshair", "walking-spread-expanded", "JDC WALK", "JIP LN"),
    (3, 1180, "JDC.dynamic-crosshair", "running-or-firing-spread-expanded", "JDC FIRE", "JIP LN"),
    (4, 1260, "JDC.dynamic-crosshair", "stopped-spread-recovered", "JDC RECOVER", "JIP LN"),
    (5, 1340, "JDC.dynamic-crosshair", "aim-down-sights-mode", "JDC ADS", "JIP LN"),
    (
        6,
        1460,
        "JDC.dynamic-crosshair",
        "interactable-prompt-coexistence",
        "JDC INTERACT",
        "JIP LN",
    ),
    (7, 1540, "JDC.dynamic-crosshair", "hostile-system-color", "JDC HOSTILE", "JIP LN"),
    (8, 1640, "JHI.hit-indicator", "front-indicator", "JHI FRONT", "JohnnyGuitar"),
    (9, 1710, "JHI.hit-indicator", "right-indicator", "JHI RIGHT", "JohnnyGuitar"),
    (10, 1780, "JHI.hit-indicator", "rear-indicator", "JHI REAR", "JohnnyGuitar"),
    (11, 1850, "JHI.hit-indicator", "left-indicator", "JHI LEFT", "JohnnyGuitar"),
    (12, 1960, "JHM.hit-marker", "normal-hit-marker", "JHM NORMAL HIT", "xNVSE core"),
    (
        13,
        2040,
        "JHM.hit-marker",
        "headshot-or-critical-marker",
        "JHM HEAD / CRITICAL",
        "xNVSE core",
    ),
    (14, 2110, "JHM.hit-marker", "kill-marker", "JHM KILL", "xNVSE core"),
    (
        15,
        2240,
        "JLM.loot-menu",
        "loot-menu-visible-authoritative-rows",
        "JLM OPEN",
        "JIP LN",
    ),
    (
        16,
        2310,
        "JLM.loot-menu",
        "single-item-transferred-exactly-once",
        "JLM TAKE",
        "JIP LN",
    ),
    (
        17,
        2370,
        "JLM.loot-menu",
        "menu-closed-crosshair-cleared",
        "JLM CLOSED",
        "JIP LN",
    ),
    (
        18,
        2460,
        "JVO.visual-objectives",
        "objective-marker-visible",
        "JVO MARKER",
        "JohnnyGuitar + JIP LN",
    ),
    (
        19,
        2540,
        "JVO.visual-objectives",
        "marker-screen-position-updated",
        "JVO MOVED",
        "JohnnyGuitar + JIP LN",
    ),
    (
        20,
        2610,
        "JVO.visual-objectives",
        "completed-or-disabled-objective-hidden",
        "JVO HIDDEN",
        "JohnnyGuitar + JIP LN",
    ),
    (21, 2700, "JWH.weapon-wheel", "wheel-open", "JWH OPEN", "JohnnyGuitar"),
    (
        22,
        2760,
        "JWH.weapon-wheel",
        "slice-one-highlighted",
        "JWH SLICE ONE",
        "JohnnyGuitar",
    ),
    (
        23,
        2820,
        "JWH.weapon-wheel",
        "selected-weapon-equipped",
        "JWH DIFFERENT SLICE",
        "JohnnyGuitar",
    ),
    (24, 2890, "JWH.weapon-wheel", "wheel-closed", "JWH CLOSE", "JohnnyGuitar"),
    (
        25,
        2980,
        "JBT.bullet-time",
        "bullet-time-active-world-slow-resource-drained",
        "JBT ACTIVE",
        "JIP LN",
    ),
    (
        26,
        3090,
        "JBT.bullet-time",
        "normal-time-restored",
        "JBT RESTORED",
        "JIP LN",
    ),
    (
        27,
        3180,
        "JHB.hold-breath",
        "hold-breath-active-and-resource-drained",
        "JHB HOLD BREATH",
        "JIP LN",
    ),
    (
        28,
        3280,
        "JHB.hold-breath",
        "hold-breath-released-baseline-restored",
        "JHB RELEASE",
        "JIP LN",
    ),
    (
        29,
        3360,
        "PROVIDER.knvse-animation",
        "override-animation-visible",
        "kNVSE OVERRIDE (NOT A JAM CALL)",
        "kNVSE",
    ),
    (
        30,
        3460,
        "PROVIDER.knvse-animation",
        "original-animation-restored",
        "kNVSE RESTORE (NOT A JAM CALL)",
        "kNVSE",
    ),
    (31, 3560, "JVS.sprint", "baseline-run", "JVS BASELINE RUN", "JIP LN"),
    (
        32,
        3660,
        "JVS.sprint",
        "sprint-at-speed-turn-and-resource-drain",
        "JVS SPRINT 1.75x",
        "JIP LN",
    ),
    (
        33,
        3770,
        "JVS.sprint",
        "sprint-release-action-points-recovering",
        "JVS RELEASE",
        "JIP LN",
    ),
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def clock_seconds(clock: str) -> float:
    hour, minute, second = clock.split(":")
    return int(hour) * 3600 + int(minute) * 60 + float(second)


def load_retail_events(path: Path) -> dict[int, dict]:
    result: dict[int, dict] = {}
    with path.open("r", encoding="utf-8") as stream:
        for line in stream:
            event = json.loads(line)
            if event.get("event") != "scheduled-console-command":
                continue
            frame = int(event.get("frame", -1))
            command = str(event.get("command", ""))
            match = re.match(r'MessageExAlt\s+\S+\s+"(?P<number>\d{2})\s', command)
            if match:
                event["telemetryFrame"] = frame
                result[int(match.group("number"))] = event
    return result


def load_openmw_phases(path: Path) -> tuple[float, dict[tuple[str, str], dict]]:
    configured = None
    phases: dict[tuple[str, str], dict] = {}
    line_pattern = re.compile(r"^\[(?P<clock>\d{2}:\d{2}:\d{2}\.\d+)[^\]]*\].*$")
    phase_pattern = re.compile(
        r"\[jam-full-proof\] state=phase-start "
        r"scenarioId=(?P<scenario>\S+) phase=(?P<phase>\S+) "
        r"sourceScript=(?P<source>.*?) provider=(?P<provider>\S+) "
        r"commandOrEvent=(?P<command>.*?) enginePath=(?P<engine>.*)$"
    )
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            clock_match = line_pattern.match(raw)
            if not clock_match:
                continue
            clock = clock_seconds(clock_match.group("clock"))
            if "[jam-full-proof] state=configured " in raw:
                configured = clock
            phase_match = phase_pattern.search(raw.rstrip())
            if phase_match:
                row = phase_match.groupdict()
                row["clock"] = clock
                phases[(row["scenario"], row["phase"])] = row
    if configured is None:
        raise RuntimeError("OpenMW log has no full-proof configured marker")
    return configured, phases


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "consolab.ttf" if bold else "consola.ttf"
    path = Path("C:/Windows/Fonts") / name
    if not path.is_file():
        path = Path("C:/Windows/Fonts/arial.ttf")
    return ImageFont.truetype(str(path), size)


def fit_text(draw: ImageDraw.ImageDraw, text: str, width: int, selected_font, lines: int = 2) -> list[str]:
    words = text.replace("_", " ").split()
    output: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if draw.textlength(candidate, font=selected_font) <= width:
            current = candidate
        else:
            if current:
                output.append(current)
            current = word
            if len(output) == lines - 1:
                break
    if current and len(output) < lines:
        output.append(current)
    return output


def make_overlay(path: Path, scene: dict) -> None:
    image = Image.new("RGBA", (1920, 650), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 540, 1919, 649), fill=(5, 8, 12, 245))
    draw.line((960, 540, 960, 649), fill=(84, 183, 255, 255), width=2)
    title_font = font(25, True)
    body_font = font(17)
    small_font = font(15)
    accent = (255, 190, 63, 255)
    cyan = (104, 210, 255, 255)
    white = (242, 244, 248, 255)
    dim = (180, 190, 204, 255)

    state = f"{scene['number']:02d}/33  {scene['label']}"
    state_width = draw.textlength(state, font=title_font)
    draw.text(((1920 - state_width) / 2, 545), state, font=title_font, fill=accent)
    draw.text((18, 577), "RETAIL FNV 1.4.0.525  •  UNTOUCHED JAM 4.6", font=body_font, fill=white)
    draw.text((978, 577), "OPENMW  •  NATIVE COMPATIBILITY", font=body_font, fill=white)
    draw.text(
        (18, 602),
        f"JAM → xNVSE dispatch → {scene['retailProvider']} → retail native effect",
        font=small_font,
        fill=cyan,
    )
    draw.text(
        (18, 625),
        (
            f"telemetry command frame {scene['retailCommandFrame']}: "
            f"accepted=true  •  native capture frame {scene['retailFrame']}"
        ),
        font=small_font,
        fill=dim,
    )
    right_line = (
        f"{scene['openMwSource']} → {scene['openMwProvider']} → "
        f"{scene['openMwCommand']} → {scene['openMwEngine']}"
    )
    wrapped = fit_text(draw, right_line, 920, small_font, 2)
    for index, line in enumerate(wrapped):
        draw.text((978, 602 + index * 23), line, font=small_font, fill=cyan if index == 0 else dim)
    image.save(path)


def run(command: list[str]) -> None:
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"Command failed ({completed.returncode}): {' '.join(command)}")


def probe(path: Path) -> dict:
    completed = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration,size",
            "-show_entries",
            "stream=width,height,avg_frame_rate,nb_frames",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--retail-video", required=True, type=Path)
    parser.add_argument("--retail-telemetry", required=True, type=Path)
    parser.add_argument("--openmw-video", required=True, type=Path)
    parser.add_argument("--openmw-log", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--scene-seconds", type=float, default=1.6)
    args = parser.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"{tool} is not on PATH")
    for source in (
        args.retail_video,
        args.retail_telemetry,
        args.openmw_video,
        args.openmw_log,
    ):
        if not source.is_file():
            raise FileNotFoundError(source)
    if args.output_root.exists():
        raise RuntimeError(f"Refusing to overwrite {args.output_root}")

    args.output_root.mkdir(parents=True)
    scenes_root = args.output_root / "scenes"
    overlays_root = args.output_root / "overlays"
    stills_root = args.output_root / "stills"
    scenes_root.mkdir()
    overlays_root.mkdir()
    stills_root.mkdir()

    retail_events = load_retail_events(args.retail_telemetry)
    configured_clock, phases = load_openmw_phases(args.openmw_log)
    manifest_scenes = []

    for number, retail_frame, scenario, phase, label, retail_provider in SCENES:
        retail_event = retail_events.get(number)
        if retail_event is None or not bool(retail_event.get("accepted")):
            raise RuntimeError(f"Missing accepted retail MessageExAlt for scene {number:02d}")
        openmw = phases.get((scenario, phase))
        if openmw is None:
            raise RuntimeError(f"Missing OpenMW phase {scenario}/{phase}")

        retail_center = (retail_frame - 850) / 60.0
        retail_start = max(0.0, retail_center - 0.15)
        openmw_phase_start = float(openmw["clock"]) - configured_clock
        openmw_start = max(0.0, openmw_phase_start + 0.55)
        scene = {
            "number": number,
            "label": label,
            "scenario": scenario,
            "phase": phase,
            "retailFrame": retail_frame,
            "retailCommandFrame": int(retail_event["telemetryFrame"]),
            "retailStartSeconds": retail_start,
            "retailCommand": retail_event.get("command"),
            "retailCommandAccepted": True,
            "retailProvider": retail_provider,
            "openMwStartSeconds": openmw_start,
            "openMwSource": openmw["source"],
            "openMwProvider": openmw["provider"],
            "openMwCommand": openmw["command"],
            "openMwEngine": openmw["engine"],
        }
        overlay = overlays_root / f"{number:02d}.png"
        clip = scenes_root / f"{number:02d}.mp4"
        still = stills_root / f"{number:02d}.png"
        make_overlay(overlay, scene)
        run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-ss",
                f"{retail_start:.6f}",
                "-i",
                str(args.retail_video),
                "-ss",
                f"{openmw_start:.6f}",
                "-i",
                str(args.openmw_video),
                "-i",
                str(overlay),
                "-t",
                f"{args.scene_seconds:.6f}",
                "-filter_complex",
                (
                    "[0:v]scale=960:540:flags=lanczos,setpts=PTS-STARTPTS[left];"
                    "[1:v]scale=960:540:flags=lanczos,setpts=PTS-STARTPTS[right];"
                    "[left][right]hstack=inputs=2,"
                    "pad=1920:650:0:0:color=black[base];"
                    "[2:v]setpts=PTS-STARTPTS[overlay];"
                    "[base][overlay]overlay=0:0:eof_action=repeat[out]"
                ),
                "-map",
                "[out]",
                "-an",
                "-r",
                "60",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "18",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                str(clip),
            ]
        )
        run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-ss",
                f"{args.scene_seconds / 2:.4f}",
                "-i",
                str(clip),
                "-frames:v",
                "1",
                str(still),
            ]
        )
        scene["clip"] = str(clip)
        scene["clipSha256"] = sha256(clip)
        scene["still"] = str(still)
        scene["stillSha256"] = sha256(still)
        manifest_scenes.append(scene)

    concat_path = args.output_root / "scenes.ffconcat"
    concat_lines = ["ffconcat version 1.0"]
    for scene in manifest_scenes:
        escaped = scene["clip"].replace("'", "'\\''")
        concat_lines.append(f"file '{escaped}'")
    concat_path.write_text("\n".join(concat_lines) + "\n", encoding="utf-8")

    video_path = args.output_root / "Retail-vs-OpenMW-JAM-4.6-telemetry-proof.mp4"
    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_path),
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            str(video_path),
        ]
    )

    still_paths = [Path(scene["still"]) for scene in manifest_scenes]
    tile_width, tile_height = 640, 217
    columns = 3
    rows = math.ceil(len(still_paths) / columns)
    sheet = Image.new("RGB", (tile_width * columns, 74 + tile_height * rows), (9, 12, 18))
    draw = ImageDraw.Draw(sheet)
    header_font = font(28, True)
    subtitle_font = font(17)
    draw.text((18, 10), "JAM 4.6 — RETAIL FNV vs OPENMW — 33 TELEMETRY-BACKED STATES", font=header_font, fill=(255, 196, 74))
    draw.text(
        (18, 45),
        "Each tile: retail native backbuffer (left) | OpenMW self-driven capture (right)",
        font=subtitle_font,
        fill=(190, 207, 228),
    )
    for index, still_path in enumerate(still_paths):
        image = Image.open(still_path).convert("RGB")
        image.thumbnail((tile_width, tile_height), Image.Resampling.LANCZOS)
        x = (index % columns) * tile_width
        y = 74 + (index // columns) * tile_height
        sheet.paste(image, (x, y))
    sheet_path = args.output_root / "Retail-vs-OpenMW-JAM-4.6-contact-sheet.png"
    sheet.save(sheet_path, optimize=True)

    video_probe = probe(video_path)
    manifest = {
        "schema": "nikami-fnv-jam-side-by-side-proof/v1",
        "status": "pass",
        "generatedAt": datetime.now().astimezone().isoformat(),
        "capturePolicy": {
            "windowsAppControlUsed": False,
            "foregroundActivationUsed": False,
            "foregroundInputInjected": False,
            "syntheticGameplayFrames": 0,
            "splices": "33 explicitly numbered and telemetry-backed state cuts",
        },
        "sources": {
            "retailVideo": str(args.retail_video),
            "retailVideoSha256": sha256(args.retail_video),
            "retailTelemetry": str(args.retail_telemetry),
            "retailTelemetrySha256": sha256(args.retail_telemetry),
            "openMwVideo": str(args.openmw_video),
            "openMwVideoSha256": sha256(args.openmw_video),
            "openMwLog": str(args.openmw_log),
            "openMwLogSha256": sha256(args.openmw_log),
        },
        "sceneSeconds": args.scene_seconds,
        "sceneCount": len(manifest_scenes),
        "scenes": manifest_scenes,
        "video": {
            "path": str(video_path),
            "sha256": sha256(video_path),
            "bytes": video_path.stat().st_size,
            "probe": video_probe,
        },
        "contactSheet": {
            "path": str(sheet_path),
            "sha256": sha256(sheet_path),
            "bytes": sheet_path.stat().st_size,
        },
    }
    manifest_path = args.output_root / "side-by-side-proof-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
