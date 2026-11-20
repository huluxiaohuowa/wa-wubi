#!/usr/bin/env python3
"""Regenerate the Swift table from CLDR 48.2 common/annotations/{zh,zh_Hant}.xml."""

from collections import defaultdict
from pathlib import Path
import re
import sys
from xml.etree import ElementTree


def generate(annotations: Path, palette: Path) -> str:
    emoji_by_sequence = {}
    for line in palette.read_text(encoding="utf-8").splitlines():
        _, emoji, _ = line.split("\t", 2)
        emoji_by_sequence.setdefault(emoji.replace("\ufe0f", ""), emoji)
    order = {emoji: index for index, emoji in enumerate(emoji_by_sequence.values())}

    han = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]+")
    scores = defaultdict(dict)
    for locale in ("zh", "zh_Hant"):
        rows = ElementTree.parse(annotations / f"{locale}.xml").findall("./annotations/annotation")
        names = {
            row.attrib["cp"]: row.text
            for row in rows
            if row.get("type") == "tts" and row.text
        }
        for row in rows:
            sequence = row.attrib["cp"]
            emoji = emoji_by_sequence.get(sequence.replace("\ufe0f", ""))
            if emoji is None or not row.text:
                continue
            name = names.get(sequence, "")
            for word in map(str.strip, row.text.split("|")):
                if not han.fullmatch(word):
                    continue
                if word == name:
                    score = 0
                elif word in name:
                    score = 1
                elif len(word) > 1:
                    score = 2
                else:
                    continue
                scores[word][emoji] = min(score, scores[word].get(emoji, score))

    lines = []
    for word, matches in sorted(scores.items()):
        ranked = sorted(matches, key=lambda emoji: (matches[emoji], order[emoji]))
        lines.append(f"    {word}\t" + " ".join(ranked[:8]))
    return "\n".join(lines)


if __name__ == "__main__":
    repo = Path(__file__).resolve().parents[1]
    target = repo / "Sources/Core/EmojiAnnotations.swift"
    prefix, _, suffix = target.read_text(encoding="utf-8").split('"""', 2)
    rows = generate(Path(sys.argv[1]), repo / "Mobile/Resources/Emoji.tsv")
    target.write_text(f'{prefix}"""\n{rows}\n    """{suffix}', encoding="utf-8")
