import argparse
import hashlib
from pathlib import Path

from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("mtl", nargs="+")
    args = parser.parse_args()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    converted = {}

    for material_name in args.mtl:
        material_path = Path(material_name).resolve()
        rewritten = []
        for raw in material_path.read_text(encoding="utf-8-sig", errors="ignore").splitlines():
            if not raw.startswith("map_Kd "):
                rewritten.append(raw)
                continue
            source = Path(raw.split(maxsplit=1)[1].strip().replace("/", "\\"))
            if not source.is_absolute():
                source = material_path.parent / source
            digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
            target = output_dir / f"{digest}-{source.stem}-rgb.png"
            if source not in converted:
                with Image.open(source) as image:
                    image.convert("RGB").save(target, optimize=True)
                converted[source] = target
            rewritten.append(f"map_Kd {target.as_posix()}")
        material_path.write_text("\n".join(rewritten) + "\n", encoding="utf-8")

    print(f"OPENDAO_OPAQUE_DIFFUSE sources={len(converted)} output={output_dir}")


if __name__ == "__main__":
    main()
