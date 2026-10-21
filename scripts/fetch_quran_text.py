#!/usr/bin/env python3
"""Builds app/assets/quran/uthmani.json from the Tanzil Uthmani Quran text.

The app never downloads anything. A maintainer runs this script once, on a
computer with internet access (or with a Tanzil file already on disk), and
commits the result.

Usage
-----
    # 1. Download from tanzil.net (you accept Tanzil's terms of use:
    #    https://tanzil.net/download/ ) and build the asset:
    python3 scripts/fetch_quran_text.py --download

    # 2. Or build from a Tanzil XML file you already have, e.g. one saved
    #    from https://tanzil.net/download/ ("Quran type: Uthmani",
    #    "Output file format: XML"):
    python3 scripts/fetch_quran_text.py --from-file quran-uthmani.xml \\
        --obtained-from "tanzil.net download, 2026-10-19"

    # Print per-surah letter counts (used for the length rule in
    # packages/salah_core/lib/src/content.dart):
    python3 scripts/fetch_quran_text.py --from-file quran-uthmani.xml --stats

Rules this script enforces
--------------------------
* The text is copied verbatim. Tanzil's terms allow verbatim copies only
  ("CHANGING IT IS NOT ALLOWED"), so the script never edits a character: it
  only selects whole ayahs of the surahs the app uses.
* Tanzil's copyright block must be present in the input. It is copied, line
  for line, into the output's "copyright" field, as Tanzil's terms require.
* Ayah counts must match the Hafs numbering the app uses.

Translations and transliterations are NOT handled here. Tanzil's
translations carry their own, separate terms (most are for non-commercial
use only and some are copyrighted by their translators or publishers). Only
add one after checking its licence; see NOTICE.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

# Al-Fatiha and the 15 pilot surahs, with Hafs ayah counts (Al-Fatiha
# counts the basmalah as ayah 1).
AYAH_COUNTS = {
    1: 7, 93: 11, 94: 8, 95: 8, 97: 5, 102: 8, 103: 3, 105: 5, 106: 4,
    107: 7, 108: 3, 109: 6, 110: 3, 112: 4, 113: 5, 114: 6,
}

# Tanzil's download form. Check https://tanzil.net/download/ if this ever
# changes. "agree=true" records that you accept Tanzil's terms of use.
DOWNLOAD_URL = (
    "https://tanzil.net/pub/download/index.php"
    "?quranType=uthmani&outType=xml&marks=true&sajdah=true&rub=true"
    "&tatweel=true&agree=true"
)

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "app" / "assets" / "quran" / "uthmani.json"


def copyright_block(raw: str) -> list[str]:
    """Returns the Tanzil copyright block lines, exactly as in the file."""
    start = raw.find("<!--")
    end = raw.find("-->")
    if start < 0 or end < 0 or "Tanzil" not in raw[start:end]:
        sys.exit("error: no Tanzil copyright block found; refusing to continue")
    lines = raw[start + 4:end].strip("\n").splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return lines


def source_title(block: list[str]) -> str:
    for line in block:
        text = line.lstrip("# ").strip()
        if text.startswith("Tanzil Quran Text"):
            return text
    sys.exit("error: copyright block has no 'Tanzil Quran Text' line")


def parse(raw: str) -> dict[int, dict]:
    root = ET.fromstring(raw.encode("utf-8"))
    surahs: dict[int, dict] = {}
    for sura in root.iter("sura"):
        number = int(sura.get("index"))
        ayahs = sura.findall("aya")
        surahs[number] = {
            "name": sura.get("name"),
            "bismillah": ayahs[0].get("bismillah") if ayahs else None,
            "ayahs": [(int(a.get("index")), a.get("text")) for a in ayahs],
        }
    return surahs


def letters(text: str) -> int:
    """Counts Arabic letters (Unicode category Lo). A rough length measure."""
    return sum(1 for ch in text if unicodedata.category(ch) == "Lo")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--download", action="store_true",
                     help="download the XML from tanzil.net")
    src.add_argument("--from-file", type=Path,
                     help="a Tanzil Quran XML file (with its copyright block)")
    p.add_argument("--obtained-from", default=None,
                   help="where the input file came from (recorded in the output)")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--stats", action="store_true",
                   help="print ayah and letter counts instead of writing")
    args = p.parse_args()

    if args.download:
        with urllib.request.urlopen(DOWNLOAD_URL, timeout=60) as r:  # noqa: S310
            data = r.read()
        obtained = args.obtained_from or f"downloaded from {DOWNLOAD_URL}"
    else:
        data = args.from_file.read_bytes()
        obtained = args.obtained_from or f"local file {args.from_file.name}"

    raw = data.decode("utf-8")
    block = copyright_block(raw)
    surahs = parse(raw)

    for number, count in AYAH_COUNTS.items():
        got = len(surahs.get(number, {}).get("ayahs", []))
        if got != count:
            sys.exit(f"error: surah {number} has {got} ayahs, expected {count}")
        indexes = [i for i, _ in surahs[number]["ayahs"]]
        if indexes != list(range(1, count + 1)):
            sys.exit(f"error: surah {number} ayah numbering is not 1..{count}")

    if args.stats:
        for number in AYAH_COUNTS:
            texts = [t for _, t in surahs[number]["ayahs"]]
            print(f"{number:3d} ayahs={len(texts):2d} letters={letters(''.join(texts))}")
        return

    out = {
        "source": source_title(block),
        "url": "https://tanzil.net",
        "licence": "Creative Commons Attribution 3.0, verbatim copies only "
                   "(see 'copyright' below, reproduced as Tanzil requires)",
        "obtainedFrom": obtained,
        "inputSha256": hashlib.sha256(data).hexdigest(),
        "extract": "Complete ayahs of Al-Fatiha and the 15 pilot surahs. "
                   "Not a character of the text has been changed.",
        "copyright": block,
        "surahs": {
            str(n): {
                "name": surahs[n]["name"],
                **({"bismillah": surahs[n]["bismillah"]}
                   if surahs[n]["bismillah"] else {}),
                "ayahs": [t for _, t in surahs[n]["ayahs"]],
            }
            for n in AYAH_COUNTS
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n",
                        encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
