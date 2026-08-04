import argparse
import os


def read_material_maps(path: str) -> dict[str, list[str]]:
    maps: dict[str, list[str]] = {}
    current = ""
    source_dir = os.path.dirname(os.path.abspath(path))
    with open(path, encoding="utf-8", errors="ignore") as stream:
        for raw in stream:
            line = raw.rstrip("\r\n")
            if line.startswith("newmtl "):
                current = line[7:].strip()
            # OpenMW's fixed-function proof path can sample a second OBJ texture as
            # colour. DAO's DXT5NM normal maps then multiply the diffuse atlas purple.
            # Keep only base colour here; normals belong in the later shader path.
            elif current and line.startswith("map_Kd "):
                directive, texture = line.split(maxsplit=1)
                absolute = os.path.normpath(os.path.join(source_dir, texture))
                maps.setdefault(current, []).append(f"{directive} {absolute.replace(os.sep, '/')}")
    return maps


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    maps = read_material_maps(args.source)
    with open(args.target, encoding="utf-8", errors="ignore") as stream:
        lines = stream.read().splitlines()
    merged: list[str] = []
    matched = 0
    for line in lines:
        merged.append(line)
        if line.startswith("newmtl "):
            material = line[7:].strip()
            if material in maps:
                merged.extend(maps[material])
                matched += 1
    with open(args.target, "w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(merged) + "\n")
    print(f"OPENDAO_MTL_MERGE matched={matched} available={len(maps)} target={args.target}")


if __name__ == "__main__":
    main()
