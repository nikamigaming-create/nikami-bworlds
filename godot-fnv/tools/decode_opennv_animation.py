#!/usr/bin/env python3
"""Validate and summarize an ONVANIM1 authored animation payload."""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path


def decode_bytes(data: bytes) -> dict:
    offset = 0

    def read(fmt: str):
        nonlocal offset
        size = struct.calcsize("<" + fmt)
        if offset + size > len(data):
            raise ValueError(f"truncated payload at {offset}")
        value = struct.unpack_from("<" + fmt, data, offset)
        offset += size
        return value[0] if len(value) == 1 else value

    def read_string() -> str:
        nonlocal offset
        size = read("I")
        if size > 1_000_000 or offset + size > len(data):
            raise ValueError(f"invalid string size {size} at {offset}")
        value = data[offset : offset + size].decode("utf-8")
        offset += size
        return value

    if data[:8] != b"ONVANIM1":
        raise ValueError("bad ONVANIM1 magic")
    offset = 8
    version, sample_rate, duration, frame_count, track_count, text_key_count = read("IffIII")
    if version != 1 or not (0 < frame_count <= 36_000) or track_count > 10_000:
        raise ValueError("invalid header")
    text_keys = [{"time": read("f"), "text": read_string()} for _ in range(text_key_count)]
    if any(not math.isfinite(row["time"]) or row["time"] < 0 or row["time"] > duration + 1e-4 for row in text_keys):
        raise ValueError("text key lies outside animation duration")
    tracks = []
    track_names: set[str] = set()
    nonfinite_values = 0
    zero_quaternions = 0
    for _ in range(track_count):
        name = read_string()
        canonical_name = name.casefold()
        if not name or canonical_name in track_names:
            raise ValueError(f"empty or duplicate animation track: {name!r}")
        track_names.add(canonical_name)
        channel_frames = {"translation": 0, "rotation": 0, "scale": 0}
        for frame_index in range(frame_count):
            flags = read("B")
            if flags & ~7:
                raise ValueError(f"invalid channel flags {flags} in {name} frame {frame_index} offset {offset - 1}")
            if flags & 1:
                values = read("fff")
                channel_frames["translation"] += 1
                nonfinite_values += sum(not math.isfinite(value) for value in values)
            if flags & 2:
                values = read("ffff")
                channel_frames["rotation"] += 1
                nonfinite_values += sum(not math.isfinite(value) for value in values)
                zero_quaternions += sum(value * value for value in values) <= 1e-12
            if flags & 4:
                value = read("f")
                channel_frames["scale"] += 1
                nonfinite_values += not math.isfinite(value)
        tracks.append({"name": name, "channel_frames": channel_frames})
    if offset != len(data):
        raise ValueError(f"trailing bytes: {len(data) - offset}")
    # The producer computes this expression in C++ float precision. Re-round
    # the product to float32 before applying ceil so values such as 7.8 * 30
    # do not acquire a Python-double epsilon and spuriously demand one frame.
    duration_frames_f32 = struct.unpack("<f", struct.pack("<f", duration * sample_rate))[0]
    if frame_count != math.ceil(duration_frames_f32) + 1:
        raise ValueError("frame count is inconsistent with duration and sample rate")
    if nonfinite_values:
        raise ValueError(f"payload contains {nonfinite_values} nonfinite values")
    if zero_quaternions:
        raise ValueError(f"payload contains {zero_quaternions} zero quaternions")
    return {
        "version": version,
        "sample_rate": sample_rate,
        "duration": duration,
        "frame_count": frame_count,
        "track_count": track_count,
        "text_keys": text_keys,
        "tracks": tracks,
        "nonfinite_values": nonfinite_values,
        "zero_quaternions": zero_quaternions,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("payload", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = decode_bytes(args.payload.read_bytes())
    rendered = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
