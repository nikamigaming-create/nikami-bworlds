#!/usr/bin/env python3
"""Create a compact Collada scene containing selected geometry instances."""

from __future__ import annotations

import argparse
import pathlib
import xml.etree.ElementTree as ET


COLLADA_NS = "http://www.collada.org/2005/11/COLLADASchema"
NS = {"c": COLLADA_NS}
ET.register_namespace("", COLLADA_NS)


def referenced_ids(elements: list[ET.Element], path: str, attribute: str) -> set[str]:
    result: set[str] = set()
    for element in elements:
        for reference in element.findall(path, NS):
            value = reference.get(attribute, "")
            if value.startswith("#"):
                result.add(value[1:])
    return result


def retain_ids(library: ET.Element | None, ids: set[str]) -> int:
    if library is None:
        return 0
    removed = 0
    for child in list(library):
        if child.get("id") not in ids:
            library.remove(child)
            removed += 1
    return removed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--keep-prefix", action="append", default=[])
    parser.add_argument("--keep-node", action="append", default=[])
    args = parser.parse_args()

    prefixes = tuple(value.lower() for value in args.keep_prefix)
    keep_nodes = set(args.keep_node)
    if not prefixes and not keep_nodes:
        parser.error("at least one --keep-prefix or --keep-node is required")

    tree = ET.parse(args.input)
    root = tree.getroot()
    visual_scene = root.find("c:library_visual_scenes/c:visual_scene", NS)
    if visual_scene is None:
        raise ValueError("Collada document has no visual scene")

    kept_nodes: list[ET.Element] = []
    removed_nodes = 0
    for node in list(visual_scene):
        instance = node.find("c:instance_geometry", NS)
        geometry_id = "" if instance is None else instance.get("url", "").removeprefix("#")
        keep = node.get("id") in keep_nodes or geometry_id.lower().startswith(prefixes)
        if keep:
            kept_nodes.append(node)
        else:
            visual_scene.remove(node)
            removed_nodes += 1

    geometry_ids = referenced_ids(kept_nodes, ".//c:instance_geometry", "url")
    material_ids = referenced_ids(kept_nodes, ".//c:instance_material", "target")
    geometry_library = root.find("c:library_geometries", NS)
    material_library = root.find("c:library_materials", NS)
    effect_library = root.find("c:library_effects", NS)
    image_library = root.find("c:library_images", NS)

    material_elements = (
        []
        if material_library is None
        else [child for child in material_library if child.get("id") in material_ids]
    )
    effect_ids = referenced_ids(material_elements, ".//c:instance_effect", "url")
    effect_elements = (
        []
        if effect_library is None
        else [child for child in effect_library if child.get("id") in effect_ids]
    )
    image_ids: set[str] = set()
    for effect in effect_elements:
        for init_from in effect.findall(".//c:init_from", NS):
            if init_from.text:
                image_ids.add(init_from.text.strip())

    removed_geometries = retain_ids(geometry_library, geometry_ids)
    removed_materials = retain_ids(material_library, material_ids)
    removed_effects = retain_ids(effect_library, effect_ids)
    removed_images = retain_ids(image_library, image_ids)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    print(
        f"kept nodes={len(kept_nodes)} geometries={len(geometry_ids)} "
        f"materials={len(material_ids)} effects={len(effect_ids)} images={len(image_ids)}"
    )
    print(
        f"removed nodes={removed_nodes} geometries={removed_geometries} "
        f"materials={removed_materials} effects={removed_effects} images={removed_images}"
    )
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
