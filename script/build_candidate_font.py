#!/usr/bin/env python3
"""Build the WA Wubi Han collection from Scriptwide Sans CJK v1.004."""

import argparse
import hashlib
from io import BytesIO
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from fontTools.ttLib import TTCollection

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "ScriptwideSansCJK.ttc"
SOURCE_SHA256 = "bc0dc3aab06763815c25d86b2c96850fb586eaa3d056966e4f779cebd8ffad43"
FAMILY = "WA Wubi Han"
STYLES = {"A": "Basic", "B": "Extensions", "C": "Extended Plane"}


def dictionary_characters():
    result = set(map(ord, "※—…·✓×→←↑↓★☆〇□■①②③"))
    for line in (ROOT / "Resources" / "wubi86.dict.yaml").read_text(encoding="utf-8").splitlines():
        columns = line.split("\t")
        if len(columns) >= 2 and not line.startswith("#") and re.fullmatch(r"[a-z]{1,4}", columns[1]):
            result.update(map(ord, columns[0]))
    return result


def rename(font, style):
    postscript = "WAWubiHan-" + style.replace(" ", "")
    table = font["name"]
    for identifier in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
        table.removeNames(nameID=identifier)
    for identifier, value in {
        1: FAMILY + " " + style, 2: "Regular", 3: postscript + "-1.0", 4: FAMILY + " " + style,
        6: postscript, 16: FAMILY, 17: style,
    }.items():
        table.setName(value, identifier, 3, 1, 0x409)
    font.recalcTimestamp = False
    return font


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    source = args.sources / SOURCE
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise ValueError(f"Unexpected upstream font: {SOURCE}")

    needed = dictionary_characters()
    collection = TTCollection(source)
    faces = {font["name"].getDebugName(6).rsplit("-", 1)[-1]: font for font in collection.fonts}
    covered = set().union(*(font.getBestCmap() for font in faces.values()))

    missing = needed - covered
    if missing:
        raise ValueError("Missing characters: " + " ".join(f"U+{cp:04X}" for cp in sorted(missing)))

    collection.fonts = [rename(faces[role], style) for role, style in STYLES.items()]
    data = BytesIO()
    collection.save(data)
    contents = {
        "WAWubiHan.ttc": data.getvalue(),
        "ScriptwideSansCJK-OFL.txt": (args.sources / "ScriptwideSansCJK-OFL.txt").read_bytes(),
    }
    with ZipFile(args.output, "w") as output:
        for name, content in contents.items():
            record = ZipInfo(name, (2025, 4, 6, 0, 0, 0))
            output.writestr(record, content, compress_type=ZIP_DEFLATED, compresslevel=9)
    print(f"WA Wubi Han covers all {len(needed):,} bundled characters and symbols.")


if __name__ == "__main__":
    main()
