#!/usr/bin/env python3
"""Export authored Skyrim dragon HKX clips into Nikami's proof runtime stream.

The output contains decompressed local bone transforms only.  The renderer
selects it by the dragon skeleton's authored bone signature, never by actor ID.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from pathlib import Path


MAGIC = b"NIKDRGN1"
VERSION = 1
DEFAULT_SEQUENCE = (
    "ground_combatidle.hkx",
    "mtforwardground.hkx",
    "mtforwardground.hkx",
    "mtforwardground.hkx",
    "mttakeoff45.hkx",
    "mtfastforward_flap.hkx",
    "mtfastforward_flap.hkx",
    "mtfastforward_flap.hkx",
    "mtfastforward_flap.hkx",
)


def _write_string(stream, value: str) -> None:
    encoded = value.encode("utf-8")
    if len(encoded) > 0xFFFF:
        raise ValueError(f"String is too long: {value!r}")
    stream.write(struct.pack("<H", len(encoded)))
    stream.write(encoded)


def _quat_multiply(left, right):
    lx, ly, lz, lw = left
    rx, ry, rz, rw = right
    return [
        lw * rx + lx * rw + ly * rz - lz * ry,
        lw * ry - lx * rz + ly * rw + lz * rx,
        lw * rz + lx * ry - ly * rx + lz * rw,
        lw * rw - lx * rx - ly * ry - lz * rz,
    ]


def _quat_rotate(rotation, vector):
    x, y, z, w = rotation
    vx, vy, vz = vector
    tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
    return [
        vx + w * tx + y * tz - z * ty,
        vy + w * ty + z * tx - x * tz,
        vz + w * tz + x * ty - y * tx,
    ]


def _ground_contact(skeleton, animation):
    positions = []
    rotations = []
    binding = animation.track_to_bone_indices
    track_by_bone = {
        (binding[index] if binding else index): track
        for index, track in enumerate(animation.tracks)
    }
    for bone_index, parent in enumerate(skeleton.parents):
        track = track_by_bone.get(bone_index)
        pose = track if track is not None else skeleton.reference_pose[bone_index]
        translation = track.translations[0] if track is not None else pose.translation
        rotation = track.rotations[0] if track is not None else pose.rotation
        if parent < 0:
            positions.append(list(translation))
            rotations.append(list(rotation))
        else:
            rotated = _quat_rotate(rotations[parent], translation)
            positions.append([positions[parent][axis] + rotated[axis] for axis in range(3)])
            rotations.append(_quat_multiply(rotations[parent], rotation))
    contacts = [
        (positions[index][2], name)
        for index, name in enumerate(skeleton.bones)
        if "LegFoot" in name or "LegToe" in name
    ]
    if not contacts:
        raise ValueError("Dragon skeleton has no authored foot/toe contact bones")
    return min(contacts)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pynifly", required=True, type=Path)
    parser.add_argument("--skeleton", required=True, type=Path)
    parser.add_argument("--animations", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--clip", action="append", dest="clips")
    args = parser.parse_args()

    hkx_module = args.pynifly / "io_scene_nifly" / "hkx"
    sys.path.insert(0, os.fspath(hkx_module))
    import anim_skyrim  # type: ignore[import-not-found]

    skeleton = anim_skyrim.load_skyrim_skeleton(os.fspath(args.skeleton))
    if skeleton is None:
        raise ValueError(f"No Skyrim skeleton found in {args.skeleton}")

    clip_names = tuple(args.clips or DEFAULT_SEQUENCE)
    clips = []
    for clip_name in clip_names:
        animation = anim_skyrim.load_skyrim_animation(
            os.fspath(args.animations / clip_name)
        )
        if animation.num_tracks > len(skeleton.bones):
            raise ValueError(
                f"{clip_name} has {animation.num_tracks} tracks but the skeleton has "
                f"only {len(skeleton.bones)} bones"
            )
        clips.append((clip_name, animation))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as stream:
        stream.write(MAGIC)
        stream.write(struct.pack("<II", VERSION, len(clips)))
        for clip_name, animation in clips:
            _write_string(stream, Path(clip_name).stem)
            stream.write(
                struct.pack(
                    "<ffII",
                    animation.duration,
                    animation.frame_duration,
                    animation.num_frames,
                    animation.num_tracks,
                )
            )
            binding = animation.track_to_bone_indices
            for track_index in range(animation.num_tracks):
                bone_index = binding[track_index] if binding else track_index
                _write_string(stream, skeleton.bones[bone_index])
                track = animation.tracks[track_index]
                if not (
                    len(track.translations)
                    == len(track.rotations)
                    == len(track.scales)
                    == animation.num_frames
                ):
                    raise ValueError(f"Incomplete track {track_index} in {clip_name}")
                for frame in range(animation.num_frames):
                    stream.write(
                        struct.pack(
                            "<10f",
                            *track.translations[frame],
                            *track.rotations[frame],
                            *track.scales[frame],
                        )
                    )

    ground_contact_z, ground_contact_bone = _ground_contact(skeleton, clips[0][1])
    metadata_path = args.output.with_suffix(".json")
    metadata_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "sourceSkeleton": os.fspath(args.skeleton),
                "clips": list(clip_names),
                "duration": sum(animation.duration for _, animation in clips),
                "groundContactBone": ground_contact_bone,
                "groundContactOffsetZ": ground_contact_z,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    seconds = sum(animation.duration for _, animation in clips)
    print(
        f"Wrote {args.output} with {len(clips)} authored clips, "
        f"{seconds:.3f}s total; ground contact {ground_contact_bone} at Z={ground_contact_z:.3f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
