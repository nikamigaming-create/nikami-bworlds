#!/usr/bin/env python3
"""Prepare a filtered COLLADA scene for material-preserving OpenMW proofs."""

from __future__ import annotations

import argparse
import pathlib
import xml.etree.ElementTree as ET


NS = "http://www.collada.org/2005/11/COLLADASchema"
Q = lambda name: f"{{{NS}}}{name}"


def colour_element(name: str, values: tuple[float, float, float, float]) -> ET.Element:
    element = ET.Element(Q(name))
    colour = ET.SubElement(element, Q("color"), {"sid": name})
    colour.text = " ".join(f"{value:.6g}" for value in values)
    return element


def scalar_element(name: str, value: float) -> ET.Element:
    element = ET.Element(Q(name))
    scalar = ET.SubElement(element, Q("float"), {"sid": name})
    scalar.text = f"{value:.6g}"
    return element


def replace_child(parent: ET.Element, name: str, replacement: ET.Element, before: str) -> None:
    current = parent.find(Q(name))
    if current is not None:
        parent.remove(current)
    children = list(parent)
    index = next((i for i, child in enumerate(children) if child.tag == Q(before)), len(children))
    parent.insert(index, replacement)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--replace", action="append", default=[], metavar="OLD=NEW")
    args = parser.parse_args()

    replacements = {}
    for value in args.replace:
        old, separator, new = value.partition("=")
        if not separator:
            parser.error(f"--replace expects OLD=NEW: {value}")
        replacements[old] = new

    ET.register_namespace("", NS)
    tree = ET.parse(args.input)
    root = tree.getroot()
    for init_from in root.findall(f".//{Q('library_images')}/{Q('image')}/{Q('init_from')}"):
        if init_from.text in replacements:
            init_from.text = replacements[init_from.text]

    for effect in root.findall(f".//{Q('library_effects')}/{Q('effect')}"):
        name = (effect.get("name") or effect.get("id") or "").lower()
        phong = effect.find(f".//{Q('phong')}")
        if phong is None:
            continue
        if "door" in name:
            ambient, specular, shininess = 0.52, 0.025, 7.0
        elif "plaza" in name:
            ambient, specular, shininess = 0.58, 0.012, 4.0
        else:
            ambient, specular, shininess = 0.55, 0.018, 5.0
        replace_child(phong, "ambient", colour_element("ambient", (ambient, ambient, ambient, 1.0)), "diffuse")
        replace_child(phong, "specular", colour_element("specular", (specular, specular, specular, 1.0)), "shininess")
        replace_child(phong, "shininess", scalar_element("shininess", shininess), "reflective")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(tree, space="  ")
    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
