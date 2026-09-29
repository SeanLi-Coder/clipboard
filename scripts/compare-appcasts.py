#!/usr/bin/env python3
"""Compare signed appcast build numbers without changing their signed bytes."""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def latest_version(path: str) -> tuple[int, int, int]:
    data = Path(path).read_bytes()
    if len(data) > 1024 * 1024:
        raise ValueError("The appcast exceeds the expected size limit.")
    versions = []
    for item in ET.fromstring(data).findall("./channel/item"):
        enclosure = item.find("enclosure")
        raw = item.findtext(SPARKLE + "version")
        if raw is None and enclosure is not None:
            raw = enclosure.get(SPARKLE + "version")
        if not raw or not re.fullmatch(r"[0-9]+(?:\.[0-9]+\.[0-9]+)?", raw):
            raise ValueError("The appcast contains an unsupported build number.")
        components = tuple(map(int, raw.split(".")))
        versions.append(components + (0,) * (3 - len(components)))
    if not versions:
        raise ValueError("The appcast contains no update versions.")
    return max(versions)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: compare-appcasts.py candidate.xml current.xml")
    try:
        candidate, current = map(latest_version, sys.argv[1:])
    except (ValueError, OSError, ET.ParseError) as error:
        raise SystemExit(str(error)) from None
    print("newer" if candidate > current else "older" if candidate < current else "same")
