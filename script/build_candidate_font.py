#!/usr/bin/env python3
"""Build the WA Wubi Han collection from pinned Jigmo and Noto fonts."""

import argparse
from datetime import datetime
import hashlib
from io import BytesIO
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from fontTools import subset
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "Jigmo-20250912.zip": "5744c7386d129475d87607ca66d043c8793c65448adeaedc921b6931890e5d0b",
    "NotoSansSC.ttf": "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da",
    "NotoSansMath.ttf": "3f495fe933c06786e4d5f6d86b8ee70b6753a68ee3b9d87528726de0f6e2c47d",
}
FAMILY = "WA Wubi Han"
STYLES = ("Basic", "Extensions", "Extended Plane", "Symbols", "Math")


def dictionary_characters():
    result = set(map(ord, "※—…·✓×→←↑↓★☆〇□■①②③"))
    for line in (ROOT / "Resources" / "wubi86.dict.yaml").read_text(encoding="utf-8").splitlines():
        columns = line.split("\t")
        if len(columns) >= 2 and not line.startswith("#") and re.fullmatch(r"[a-z]{1,4}", columns[1]):
            result.update(map(ord, columns[0]))
    return result


def supplement(path, characters):
    font = TTFont(path, recalcTimestamp=False)
    subsetter = subset.Subsetter()
    subsetter.populate(unicodes=characters)
    subsetter.subset(font)
    if "fvar" in font:
        font = instantiateVariableFont(font, {"wght": 400}, inplace=True)
    return font


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

    for name, digest in SOURCES.items():
        if hashlib.sha256((args.sources / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Unexpected upstream font: {name}")

    needed = dictionary_characters()
    with ZipFile(args.sources / "Jigmo-20250912.zip") as upstream:
        fonts = [TTFont(BytesIO(upstream.read(name))) for name in ("Jigmo.ttf", "Jigmo2.ttf", "Jigmo3.ttf")]
        jigmo_license = upstream.read("LICENSE.txt")
    covered = set().union(*(font.getBestCmap() for font in fonts))
    # Include additional punctuation and symbols for imported dictionaries.
    for name in ("NotoSansSC.ttf", "NotoSansMath.ttf"):
        available = set(TTFont(args.sources / name, lazy=True).getBestCmap())
        symbols = {cp for cp in available if cp < 0x3400 or 0xFE00 <= cp <= 0xFFEF}
        font = supplement(args.sources / name, (symbols | needed) - covered)
        fonts.append(font)
        covered.update(font.getBestCmap())

    missing = needed - covered
    if missing:
        raise ValueError("Missing characters: " + " ".join(f"U+{cp:04X}" for cp in sorted(missing)))

    collection = TTCollection()
    collection.fonts = [rename(font, style) for font, style in zip(fonts, STYLES)]
    data = BytesIO()
    collection.save(data)
    contents = {
        "WAWubiHan.ttc": data.getvalue(),
        "Jigmo-CC0.txt": jigmo_license,
        "NotoSansSC-OFL.txt": (args.sources / "NotoSansSC-OFL.txt").read_bytes(),
        "NotoSansMath-OFL.txt": (args.sources / "NotoSansMath-OFL.txt").read_bytes(),
    }
    with ZipFile(args.output, "w") as output:
        for name, content in contents.items():
            record = ZipInfo(name, datetime(2025, 9, 12).timetuple()[:6])
            output.writestr(record, content, compress_type=ZIP_DEFLATED, compresslevel=9)
    print(f"WA Wubi Han covers all {len(needed):,} bundled characters and symbols.")


if __name__ == "__main__":
    main()
