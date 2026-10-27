#!/usr/bin/env python3
"""Builds Sources/KlavkoCore/Emoji: the emoji in Unicode's order and their names and keywords in each
language Klavko knows (Unicode CLDR), for typing emoji by name.

    scripts/make-emoji-data.py            # downloads Unicode's lists and writes the files

Run again for a newer Unicode or CLDR; the files are checked in, the app reads them offline.
"""
import json, pathlib, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources" / "KlavkoCore" / "Emoji"
EMOJI_VERSION = "16.0"
# SystemLayouts.supportedLanguages
LANGUAGES = ["uk", "en", "ru", "de", "fr", "es", "it", "pt", "pl", "tr", "el", "he", "ar"]
CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json"
SKIN_TONES = {chr(c) for c in range(0x1F3FB, 0x1F400)}


def fetch(url):
    with urllib.request.urlopen(url) as response:
        return response.read().decode("utf-8")


def key(emoji):
    """CLDR names emoji without the variation selector."""
    return emoji.replace("️", "")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    order = []
    group = ""
    for line in fetch(f"https://unicode.org/Public/emoji/{EMOJI_VERSION}/emoji-test.txt").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
        if "; fully-qualified" not in line or group == "Component":
            continue
        emoji, version = line.split("#", 1)[1].split()[:2]
        # Skin tones are variants of one emoji: only the plain one is listed.
        if SKIN_TONES & set(emoji):
            continue
        order.append((emoji, version.lstrip("E")))
    (OUT / "order.txt").write_text("".join(f"{emoji}\t{version}\n" for emoji, version in order))

    for language in LANGUAGES:
        names = {}
        for kind, path in (("annotations", f"cldr-annotations-full/annotations/{language}/annotations.json"),
                           ("annotationsDerived", f"cldr-annotations-derived-full/annotationsDerived/{language}/annotations.json")):
            data = json.loads(fetch(f"{CLDR}/{path}"))[kind]["annotations"]
            for emoji, entry in data.items():
                names.setdefault(emoji, entry)
        lines = []
        for emoji, _ in order:
            entry = names.get(key(emoji))
            if not entry:
                continue
            name = (entry.get("tts") or [""])[0]
            keywords = [word for word in entry.get("default", []) if word != name]
            lines.append(f"{emoji}\t{name}\t{'|'.join(keywords)}\n")
        (OUT / f"{language}.txt").write_text("".join(lines))
        print(f"{language}: {len(lines)} of {len(order)}")


if __name__ == "__main__":
    main()
