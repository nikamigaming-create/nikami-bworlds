#!/usr/bin/env python3
"""Build a conservative Starfield material-to-diffuse bridge from materialsbeta.cdb.

The renderer sees compiled ``Materials/.../*.mat`` names in Starfield NIFs, but
OpenMW does not yet understand Bethesda's compiled material database.  This
tool mines the database's tagged DIFF records, groups authored texture-set
labels with their texture paths, and resolves only high-confidence matches for
materials observed in a native OpenMW proof log.

The output is a public-safe TSV containing paths and match evidence; it never
copies retail texture bytes.  A separate local cache step extracts the listed
DDS files from the user's own BA2 archives and converts them to PNG for the
current compatibility renderer.
"""

from __future__ import annotations

import argparse
import csv
import difflib
import functools
import re
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator


DIFF_LABEL_PROPERTY = 0x1F4
DIFF_TEXTURE_PATH_PROPERTY = 0x38A
MATERIAL_RE = re.compile(r'material="([^"]+\.mat)"', re.IGNORECASE)
TEXTURE_SET_SUFFIX_RE = re.compile(r"_textureset\d+$", re.IGNORECASE)
MATERIAL_TEXTURE_SET_RE = re.compile(
    r"^(?:data[\\/])?(materials[\\/].+?\.mat)_textureset\d+$", re.IGNORECASE
)
COLOR_TEXTURE_RE = re.compile(r"(?:_color|_diffuse|_d)\.dds$", re.IGNORECASE)

# Exact authored aliases whose compiled material name and texture-set label use
# different suffixes.  Every path below was observed in materialsbeta.cdb; the
# table does not invent retail asset names.
AUTHORED_ALIASES = {
    "materials/architecture/city/newatlantis/nadecaltrimdetails01.mat":
        "textures/architecture/city/newatlantis/nadecaltrimdetails01_color.dds",
    "materials/architecture/city/newatlantis/nadecaltrimdetails01n.mat":
        "textures/architecture/city/newatlantis/nadecaltrimdetails01_color.dds",
    "materials/architecture/city/newatlantis/nametaltrimtech04.mat":
        "textures/common/trim/trimtech04_color.dds",
    "materials/architecture/city/newatlantis/naterminalsignageuclogo01.mat":
        "textures/architecture/city/newatlantis/naterminaluclogo01_color.dds",
    "materials/architecture/city/newatlantis/signage/na_signage_spaceportinn_muralext01.mat":
        "textures/architecture/city/newatlantis/signage/nasignagespaceportinnmuralint01_color.dds",
    "materials/architecture/city/newatlantis/signage/na_signage_spaceportinn_muralext01b.mat":
        "textures/architecture/city/newatlantis/signage/nasignagespaceportinnmuralint01b_color.dds",
    "materials/architecture/city/newatlantis/signage/na_signage_spaceportinn_muralext02.mat":
        "textures/architecture/city/newatlantis/signage/nasignagespaceportinnmuralext02_color.dds",
    "materials/setdressing/signage/advertisements/signageadoishi01.mat":
        "textures/setdressing/signage/advertisements/signageadoishi01_color.dds",
}


@dataclass(frozen=True)
class DiffString:
    offset: int
    property_id: int
    value: str


@dataclass
class TextureSet:
    label: str
    textures: list[str]

    @property
    def color_textures(self) -> list[str]:
        return [value for value in self.textures if COLOR_TEXTURE_RE.search(value)]


@dataclass(frozen=True)
class Candidate:
    material: str
    texture: str
    texture_set: str
    score: float
    method: str


def normalize_path(value: str) -> str:
    value = value.strip().strip('"').replace("\\", "/")
    while "//" in value:
        value = value.replace("//", "/")
    if value.lower().startswith("data/"):
        value = value[5:]
    return value


def normalize_material(value: str) -> str:
    value = normalize_path(value).lower()
    if not value.startswith("materials/"):
        value = "materials/" + value.lstrip("/")
    return value


def normalize_texture(value: str) -> str:
    value = normalize_path(value).lower()
    if not value.startswith("textures/"):
        value = "textures/" + value.lstrip("/")
    return value


def alnum(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.lower())


@functools.lru_cache(maxsize=None)
def material_stem(material: str) -> str:
    return Path(material.replace("\\", "/")).name.removesuffix(".mat").lower()


@functools.lru_cache(maxsize=None)
def label_stem(label: str) -> tuple[str, str | None]:
    normalized = normalize_path(label)
    material_match = MATERIAL_TEXTURE_SET_RE.match(normalized)
    if material_match:
        linked_material = normalize_material(material_match.group(1))
        return material_stem(linked_material), linked_material
    stem = TEXTURE_SET_SUFFIX_RE.sub("", Path(normalized).name)
    return stem.lower(), None


@functools.lru_cache(maxsize=None)
def semantic_variants(stem: str) -> frozenset[str]:
    """Return cautious aliases for common layered/tinted material naming.

    Starfield frequently names a MAT as ``NAFoo_Layered01`` while its authored
    color surface is stored as ``Foo_TextureSet1``.  These transforms remove
    composition/tint words, but never invent a texture path.
    """

    stem = stem.lower()
    variants = {alnum(stem)}
    queue = [stem]
    patterns = (
        r"^na(?=[a-z])",
        r"(?:_base|_layered\d+)$",
        r"(?:_dark|_n)$",
        r"_(?:black|white|grey|gray|blue|red|green|orange|yellow|brown)\d*$",
        r"_(?:metal|plastic|paint)(?:plain|smooth|matte|textured|scuffed|worn|scratched|brushed)*\d*$",
    )
    for _ in range(3):
        next_queue: list[str] = []
        for item in queue:
            for pattern in patterns:
                reduced = re.sub(pattern, "", item, flags=re.IGNORECASE).strip("_")
                if reduced and reduced != item:
                    encoded = alnum(reduced)
                    if encoded not in variants:
                        variants.add(encoded)
                        next_queue.append(reduced)
        queue = next_queue
        if not queue:
            break
    return frozenset(value for value in variants if len(value) >= 6)


def iter_chunks(path: Path) -> Iterator[tuple[int, bytes, bytes]]:
    with path.open("rb") as stream:
        header = stream.read(16)
        if len(header) != 16 or header[:4] != b"BETH":
            raise ValueError(f"{path} is not a supported BETH compiled database")
        offset = 16
        while True:
            chunk_header = stream.read(8)
            if not chunk_header:
                return
            if len(chunk_header) != 8:
                raise ValueError(f"truncated chunk header at 0x{offset:x}")
            tag = chunk_header[:4]
            size = struct.unpack_from("<I", chunk_header, 4)[0]
            payload = stream.read(size)
            if len(payload) != size:
                raise ValueError(f"truncated {tag!r} payload at 0x{offset:x}")
            yield offset, tag, payload
            offset += 8 + size


def decode_diff_string(offset: int, payload: bytes) -> DiffString | None:
    # CompiledDB string DIFF payload:
    #   uint32 property-id, uint16 flags, uint16 byte-count, NUL-terminated text
    if len(payload) < 10:
        return None
    property_id = struct.unpack_from("<I", payload, 0)[0]
    byte_count = struct.unpack_from("<H", payload, 6)[0]
    if byte_count < 2 or 8 + byte_count > len(payload):
        return None
    raw = payload[8 : 8 + byte_count]
    if raw.endswith(b"\0"):
        raw = raw[:-1]
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not value:
        return None
    return DiffString(offset=offset, property_id=property_id, value=value)


def read_texture_sets(path: Path) -> list[TextureSet]:
    result: list[TextureSet] = []
    current: TextureSet | None = None
    for offset, tag, payload in iter_chunks(path):
        if tag != b"DIFF":
            continue
        entry = decode_diff_string(offset, payload)
        if entry is None:
            continue
        if entry.property_id == DIFF_LABEL_PROPERTY:
            if current is not None and current.textures:
                result.append(current)
            current = TextureSet(label=entry.value, textures=[])
        elif entry.property_id == DIFF_TEXTURE_PATH_PROPERTY and current is not None:
            value = normalize_path(entry.value)
            if value.lower().startswith("textures/") and value.lower().endswith(".dds"):
                current.textures.append(normalize_texture(value))
    if current is not None and current.textures:
        result.append(current)
    return result


def read_materials(log_paths: Iterable[Path], list_paths: Iterable[Path]) -> list[str]:
    values: dict[str, str] = {}
    for path in log_paths:
        for match in MATERIAL_RE.finditer(path.read_text(encoding="utf-8", errors="ignore")):
            material = normalize_material(match.group(1))
            values.setdefault(material, material)
    for path in list_paths:
        for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            material = normalize_material(line.split("\t", 1)[0])
            values.setdefault(material, material)
    return sorted(values.values())


def is_world_material(material: str) -> bool:
    return material.startswith(
        (
            "materials/architecture/",
            "materials/common/",
            "materials/effects/",
            "materials/landscape/",
            "materials/setdressing/",
            "materials/ships/",
            "materials/water/",
        )
    )


def is_unsupported_surface(material: str) -> bool:
    # These require blend/emissive/refraction semantics that a diffuse-only
    # bridge cannot reproduce honestly.  Leave them to the neutral fallback.
    key = material.lower()
    return any(
        token in key
        for token in (
            # Starfield glass color slots are frequently layer masks rather
            # than final albedo (for example NAGlassPattern02). Binding those
            # as diffuse produces an unmistakable checkerboard surface.
            "glass",
            "plaintranslucent",
            "glow",
            "lightstrip",
            "streetlamp",
            "waterfountain",
            "waterfall",
            "distortion",
        )
    )


def score_candidate(material: str, texture_set: TextureSet) -> tuple[float, str]:
    m_stem = material_stem(material)
    l_stem, linked_material = label_stem(texture_set.label)
    if linked_material == material:
        return 1.0, "compiled-material-path"
    if alnum(m_stem) == alnum(l_stem):
        return 0.99, "exact-stem"

    m_variants = semantic_variants(m_stem)
    l_variants = semantic_variants(l_stem)
    if m_variants & l_variants:
        return 0.94, "semantic-stem"

    material_key = alnum(m_stem)
    label_key = alnum(l_stem)
    # Avoid millions of meaningless SequenceMatcher calls against unrelated
    # database entries.  A fuzzy candidate must at least share a stable prefix
    # after the semantic aliases above have had their chance.
    comparable_prefix = any(
        len(left) >= 6 and len(right) >= 6 and left[:5] == right[:5]
        for left in m_variants
        for right in l_variants
    )
    if not comparable_prefix:
        return 0.0, "unrelated"
    ratio = difflib.SequenceMatcher(None, material_key, label_key).ratio()
    if ratio >= 0.90:
        return ratio * 0.95, "fuzzy-stem"
    return ratio * 0.82, "weak-fuzzy"


def choose_color(texture_set: TextureSet) -> str | None:
    colors = texture_set.color_textures
    if not colors:
        return None
    # Prefer the ordinary color map over generated LOD or specialized masks.
    return sorted(
        colors,
        key=lambda value: (
            "/lod/generated/" in value,
            "_opacity" in value,
            len(value),
            value,
        ),
    )[0]


def surface_category_compatible(material: str, texture: str) -> bool:
    """Reject misleading color dependencies from unsupported layered surfaces.

    Compiled texture sets may expose a color map used by a nested mask/layer,
    not the visible base.  A diffuse-only bridge must not turn rubber into
    galvanized metal, plastic into copper, or rock into a poster.
    """

    material_name = material_stem(material)
    texture_key = texture.lower()
    requirements = (
        ("plastic", "plastic"),
        ("rubber", "rubber"),
        ("glass", "glass"),
        ("rock", "rock"),
    )
    for material_token, texture_token in requirements:
        if material_token in material_name and texture_token not in texture_key:
            return False
    return True


def resolve_material(material: str, texture_sets: list[TextureSet]) -> Candidate | None:
    alias = AUTHORED_ALIASES.get(material)
    if alias is not None:
        return Candidate(
            material=material,
            texture=alias,
            texture_set="materialsbeta.cdb authored alias",
            score=1.0,
            method="authored-alias",
        )
    if not is_world_material(material) or is_unsupported_surface(material):
        return None
    ranked: list[Candidate] = []
    for texture_set in texture_sets:
        texture = choose_color(texture_set)
        if texture is None:
            continue
        if not surface_category_compatible(material, texture):
            continue
        score, method = score_candidate(material, texture_set)
        if score < 0.70:
            continue
        ranked.append(
            Candidate(
                material=material,
                texture=texture,
                texture_set=texture_set.label,
                score=score,
                method=method,
            )
        )
    if not ranked:
        return None
    ranked.sort(key=lambda item: (-item.score, len(item.texture), item.texture))
    best = ranked[0]
    second_score = ranked[1].score if len(ranked) > 1 else 0.0
    # Require exact/semantic evidence, or a very strong fuzzy result with a
    # useful margin.  The renderer's old broad guesses are intentionally not
    # reproduced here.
    if best.score >= 0.93:
        return best
    if best.score >= 0.84 and best.score - second_score >= 0.055:
        return best
    return None


def write_tsv(path: Path, candidates: list[Candidate], unresolved: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        stream.write("# Starfield material bridge generated from local materialsbeta.cdb\n")
        stream.write("# material\tdiffuse\tconfidence\tmethod\ttexture-set\n")
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        for item in candidates:
            writer.writerow(
                (
                    item.material,
                    item.texture,
                    f"{item.score:.4f}",
                    item.method,
                    item.texture_set,
                )
            )
        for material in unresolved:
            stream.write(f"# unresolved\t{material}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cdb", type=Path, required=True)
    parser.add_argument("--material-log", type=Path, action="append", default=[])
    parser.add_argument("--material-list", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    materials = read_materials(args.material_log, args.material_list)
    if not materials:
        parser.error("no materials were found in the supplied logs/lists")
    texture_sets = read_texture_sets(args.cdb)
    candidates: list[Candidate] = []
    unresolved: list[str] = []
    for material in materials:
        candidate = resolve_material(material, texture_sets)
        if candidate is None:
            if is_world_material(material):
                unresolved.append(material)
        else:
            candidates.append(candidate)
    candidates.sort(key=lambda item: item.material)
    unresolved.sort()
    write_tsv(args.output, candidates, unresolved)
    print(
        f"materials={len(materials)} textureSets={len(texture_sets)} "
        f"resolved={len(candidates)} unresolvedWorld={len(unresolved)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
