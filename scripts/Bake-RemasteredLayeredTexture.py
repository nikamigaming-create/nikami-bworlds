#!/usr/bin/env python3
"""Bake an exported UE layered material into one OpenMW-compatible texture.

The local proof loader currently consumes a conventional DAE/Phong material,
so a UE material-layer graph must be flattened offline.  This keeps the real
layer base-color maps and atlas blend mask, then restores UV-aligned detail
from the mesh-specific diffuse/detail atlas.  No game assets are copied into
the repository; inputs and outputs live in the ignored local proof cache.
"""

from __future__ import annotations

import argparse
import json
import pathlib

import numpy as np
from PIL import Image, ImageFilter


def rgb_value(value: str) -> tuple[float, float, float]:
    components = tuple(float(component) for component in value.split(","))
    if len(components) != 3:
        raise argparse.ArgumentTypeError("RGB values must be R,G,B")
    return components


def overlay_value(value: str) -> tuple[int, tuple[float, float, float], float, float]:
    parts = value.split(":")
    if len(parts) not in (3, 4) or parts[0].lower() not in "rgba":
        raise argparse.ArgumentTypeError("overlays must be CHANNEL:R,G,B:STRENGTH[:POWER]")
    channel = "rgba".index(parts[0].lower())
    colour = rgb_value(parts[1])
    strength = float(parts[2])
    power = float(parts[3]) if len(parts) == 4 else 1.0
    return channel, colour, strength, power


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    value = value.astype(np.float32) / 255.0
    return np.where(value <= 0.04045, value / 12.92, np.power((value + 0.055) / 1.055, 2.4))


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    encoded = np.where(value <= 0.0031308, value * 12.92, 1.055 * np.power(value, 1.0 / 2.4) - 0.055)
    return (encoded * 255.0 + 0.5).astype(np.uint8)


def resized_rgb(path: pathlib.Path, size: tuple[int, int]) -> np.ndarray:
    image = Image.open(path).convert("RGB").resize(size, Image.Resampling.LANCZOS)
    return srgb_to_linear(np.asarray(image))


def tiled_layer(
    path: pathlib.Path,
    size: tuple[int, int],
    tile_pixels: int,
    texture_strength: float,
    tint: tuple[float, float, float],
    multiply: float,
    desaturate: float,
) -> np.ndarray:
    source = Image.open(path).convert("RGB")
    source.thumbnail((tile_pixels, tile_pixels), Image.Resampling.LANCZOS)
    tile = srgb_to_linear(np.asarray(source))
    luminance = np.sum(tile * np.array([0.2126, 0.7152, 0.0722], dtype=np.float32), axis=2, keepdims=True)
    tile = tile * (1.0 - desaturate) + luminance * desaturate
    tile *= np.asarray(tint, dtype=np.float32).reshape(1, 1, 3) * multiply
    repeats_y = (size[1] + tile.shape[0] - 1) // tile.shape[0]
    repeats_x = (size[0] + tile.shape[1] - 1) // tile.shape[1]
    tiled = np.tile(tile, (repeats_y, repeats_x, 1))[: size[1], : size[0]]
    mean = np.mean(tile.reshape(-1, 3), axis=0, keepdims=True).reshape(1, 1, 3)
    return mean * (1.0 - texture_strength) + tiled * texture_strength


def detail_gain(detail: np.ndarray, radius: float) -> np.ndarray:
    luminance = np.sum(detail * np.array([0.2126, 0.7152, 0.0722], dtype=np.float32), axis=2)
    luminance_image = Image.fromarray(np.clip(luminance * 255.0, 0, 255).astype(np.uint8), mode="L")
    blurred = np.asarray(luminance_image.filter(ImageFilter.GaussianBlur(radius=radius)), dtype=np.float32) / 255.0
    return np.clip(luminance / np.maximum(blurred, 0.025), 0.42, 1.75)[:, :, None]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--detail", required=True, type=pathlib.Path)
    parser.add_argument("--mask", required=True, type=pathlib.Path)
    parser.add_argument("--base", required=True, type=pathlib.Path)
    parser.add_argument("--layer", action="append", default=[], type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--scale", type=float, default=1.0)
    parser.add_argument("--tile-pixels", type=int, default=384)
    parser.add_argument("--texture-strength", type=float, default=0.62)
    parser.add_argument("--detail-strength", type=float, default=0.82)
    parser.add_argument("--detail-radius", type=float, default=10.0)
    parser.add_argument("--base-tint", type=rgb_value, default=(1.0, 1.0, 1.0))
    parser.add_argument("--base-multiply", type=float, default=1.0)
    parser.add_argument("--base-desaturate", type=float, default=0.0)
    parser.add_argument("--layer-tint", action="append", type=rgb_value, default=[])
    parser.add_argument("--layer-multiply", action="append", type=float, default=[])
    parser.add_argument("--layer-desaturate", action="append", type=float, default=[])
    parser.add_argument("--layer-opacity", action="append", type=float, default=[])
    parser.add_argument("--overlay-mask", type=pathlib.Path)
    parser.add_argument(
        "--overlay",
        action="append",
        type=overlay_value,
        default=[],
        metavar="CHANNEL:R,G,B:STRENGTH[:POWER]",
    )
    parser.add_argument("--saturation", type=float, default=1.0)
    parser.add_argument("--contrast", type=float, default=1.0)
    parser.add_argument("--exposure", type=float, default=0.0, help="linear exposure in stops")
    args = parser.parse_args()

    if len(args.layer) > 4:
        parser.error("at most four --layer textures can map to RGBA")
    with Image.open(args.detail) as source:
        size = (
            max(1, round(source.width * args.scale)),
            max(1, round(source.height * args.scale)),
        )
    detail = resized_rgb(args.detail, size)
    mask = np.asarray(
        Image.open(args.mask).convert("RGBA").resize(size, Image.Resampling.LANCZOS), dtype=np.float32
    ) / 255.0

    if args.overlay and args.overlay_mask is None:
        parser.error("--overlay requires --overlay-mask")
    result = tiled_layer(
        args.base,
        size,
        args.tile_pixels,
        args.texture_strength,
        args.base_tint,
        args.base_multiply,
        args.base_desaturate,
    )
    for channel, path in enumerate(args.layer):
        tint = args.layer_tint[channel] if channel < len(args.layer_tint) else (1.0, 1.0, 1.0)
        multiply = args.layer_multiply[channel] if channel < len(args.layer_multiply) else 1.0
        desaturate = args.layer_desaturate[channel] if channel < len(args.layer_desaturate) else 0.0
        layer = tiled_layer(path, size, args.tile_pixels, args.texture_strength, tint, multiply, desaturate)
        opacity = args.layer_opacity[channel] if channel < len(args.layer_opacity) else 1.0
        weight = np.clip(mask[:, :, channel : channel + 1] * opacity, 0.0, 1.0)
        result = result * (1.0 - weight) + layer * weight

    gain = detail_gain(detail, args.detail_radius)
    result *= 1.0 + (gain - 1.0) * args.detail_strength
    if args.overlay_mask is not None:
        overlay_mask = np.asarray(
            Image.open(args.overlay_mask).convert("RGBA").resize(size, Image.Resampling.LANCZOS),
            dtype=np.float32,
        ) / 255.0
        for channel, colour, strength, power in args.overlay:
            weight = np.power(overlay_mask[:, :, channel : channel + 1], power) * strength
            # The dirt-style layers use mid-grey as their neutral point.  A
            # 2x colour gain retains the underlying authored texture while
            # reproducing colour variation, dirt, leaks, and highlights.
            colour_gain = np.asarray(colour, dtype=np.float32).reshape(1, 1, 3) * 2.0
            result *= 1.0 + (colour_gain - 1.0) * np.clip(weight, 0.0, 1.0)

    luminance = np.sum(result * np.array([0.2126, 0.7152, 0.0722], dtype=np.float32), axis=2, keepdims=True)
    result = luminance + (result - luminance) * args.saturation
    result = (result - 0.18) * args.contrast + 0.18
    result *= 2.0**args.exposure
    args.output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(linear_to_srgb(result), mode="RGB").save(args.output, optimize=True)
    print(
        json.dumps(
            {
                "output": str(args.output.resolve()),
                "size": list(size),
                "detail": str(args.detail.resolve()),
                "mask": str(args.mask.resolve()),
                "base": str(args.base.resolve()),
                "layers": [str(path.resolve()) for path in args.layer],
                "tilePixels": args.tile_pixels,
                "textureStrength": args.texture_strength,
                "detailStrength": args.detail_strength,
                "baseTint": list(args.base_tint),
                "baseMultiply": args.base_multiply,
                "baseDesaturate": args.base_desaturate,
                "layerTints": [list(value) for value in args.layer_tint],
                "layerMultiplies": args.layer_multiply,
                "layerDesaturates": args.layer_desaturate,
                "layerOpacities": args.layer_opacity,
                "overlayMask": str(args.overlay_mask.resolve()) if args.overlay_mask else None,
                "overlays": args.overlay,
                "saturation": args.saturation,
                "contrast": args.contrast,
                "exposure": args.exposure,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
