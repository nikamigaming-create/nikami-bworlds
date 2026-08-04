import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def bilinear(image: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    height, width = image.shape[:2]
    x = np.clip(u * (width - 1), 0.0, width - 1.0)
    # Godot samples both the decoded palette and external masks in top-left
    # image space. The glTF importer already accounts for its source UV origin.
    y = np.clip(v * (height - 1), 0.0, height - 1.0)
    x0 = np.floor(x).astype(np.int32)
    y0 = np.floor(y).astype(np.int32)
    x1 = np.minimum(x0 + 1, width - 1)
    y1 = np.minimum(y0 + 1, height - 1)
    fx = (x - x0)[..., None]
    fy = (y - y0)[..., None]
    top = image[y0, x0] * (1.0 - fx) + image[y0, x1] * fx
    bottom = image[y1, x0] * (1.0 - fx) + image[y1, x1] * fx
    return top * (1.0 - fy) + bottom * fy


def resize_weight_map(path: str, size: int) -> np.ndarray:
    # DAO stores four independent layer weights in RGBA. Pillow's RGBA resize
    # premultiplies RGB by A, interpreting the fourth weight as transparency;
    # on lak100d_19 that erased roughly 67% of the terrain coverage. Resize
    # each scalar weight plane independently and then reassemble it.
    source = Image.open(path).convert("RGBA")
    channels = [
        np.asarray(channel.resize((size, size), Image.Resampling.BILINEAR), dtype=np.float32)
        for channel in source.split()
    ]
    return np.stack(channels, axis=2) / 255.0


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    value = value / 255.0
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    encoded = np.where(value <= 0.0031308, value * 12.92, 1.055 * value ** (1.0 / 2.4) - 0.055)
    return np.clip(encoded * 255.0, 0.0, 255.0)


def bake(descriptor: dict, palette: np.ndarray, size: int, fallback: np.ndarray | None) -> Image.Image:
    mask_a = resize_weight_map(descriptor["maskA"], size)
    mask_b = resize_weight_map(descriptor["maskA2"], size)
    weights = np.concatenate((mask_a, mask_b), axis=2)
    output = np.empty((size, size, 3), dtype=np.uint8)
    pal_dim = descriptor["palDim"]
    pal_param = descriptor["palParam"]
    scales = descriptor["uvScales"]
    x_uv = (np.arange(size, dtype=np.float32) + 0.5) / size
    for row in range(0, size, 128):
        end = min(row + 128, size)
        y_uv = (np.arange(row, end, dtype=np.float32) + 0.5) / size
        u0 = np.broadcast_to(x_uv[None, :], (end - row, size))
        v0 = np.broadcast_to(y_uv[:, None], (end - row, size))
        color = np.zeros((end - row, size, 3), dtype=np.float32)
        total = np.zeros((end - row, size, 1), dtype=np.float32)
        for layer in range(8):
            weight = weights[row:end, :, layer : layer + 1]
            column = layer // int(pal_dim[3])
            atlas_row = layer % int(pal_dim[3])
            u = column * pal_dim[0] + pal_param[0] + np.mod(u0 * scales[layer], 1.0) * pal_param[2]
            v = atlas_row * pal_dim[1] + pal_param[1] + np.mod(v0 * scales[layer], 1.0) * pal_param[3]
            # Godot marks the diffuse palette as source_color, so layer
            # interpolation happens in linear light. Encode the resolved bake
            # back to sRGB for the OpenMW glTF material.
            sample = srgb_to_linear(bilinear(palette, u, v)[:, :, :3])
            color += sample * weight
            total += weight
        resolved = linear_to_srgb(color / np.maximum(total, 0.0001)).astype(np.uint8)
        if fallback is not None:
            empty = total[:, :, 0] <= 0.0001
            resolved[empty] = fallback[row:end][empty]
        output[row:end] = resolved
    return Image.fromarray(output, "RGB")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--palette")
    parser.add_argument("--palette-dir")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--fallback-dir")
    parser.add_argument("--size", type=int, default=4096)
    parser.add_argument("--materials", nargs="+", required=True)
    args = parser.parse_args()
    descriptors = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    if not args.palette and not args.palette_dir:
        parser.error("one of --palette or --palette-dir is required")
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for material in args.materials:
        palette_path = (
            Path(args.palette_dir) / f"{material}_palette.png"
            if args.palette_dir
            else Path(args.palette)
        )
        palette = np.asarray(Image.open(palette_path).convert("RGBA"), dtype=np.float32)
        fallback = None
        if args.fallback_dir:
            fallback_path = Path(args.fallback_dir) / f"{material}_openmw_baked.png"
            fallback = np.asarray(
                Image.open(fallback_path).convert("RGB").resize((args.size, args.size), Image.Resampling.BICUBIC),
                dtype=np.uint8,
            )
        image = bake(descriptors[material], palette, args.size, fallback)
        output = output_dir / f"{material}_openmw_baked_4k.png"
        image.save(output, optimize=True)
        print(
            f"OPENDAO_TERRAIN_BAKE material={material} palette={palette_path} "
            f"size={args.size} output={output}"
        )


if __name__ == "__main__":
    main()
