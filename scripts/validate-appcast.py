#!/usr/bin/env python3
"""Validate the release metadata before verifying its EdDSA signatures."""

import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

if len(sys.argv) != 5:
    raise SystemExit("Usage: validate-appcast.py feed.xml version download-url archive.dmg")
feed_path, version, download_url, archive_path = sys.argv[1:]
data = Path(feed_path).read_bytes()
if len(data) > 1024 * 1024:
    raise SystemExit("The appcast exceeds the expected size limit.")
namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.fromstring(data).findall("./channel/item")
if len(items) != 1:
    raise SystemExit("The update feed must contain exactly one release.")
item = items[0]
if item.findtext("sparkle:shortVersionString", namespaces=namespace) != version:
    raise SystemExit("The archive version does not match its filename.")
if item.findtext("sparkle:version", namespaces=namespace) != version:
    raise SystemExit("The update build number must match its release version.")
if item.findtext("sparkle:hardwareRequirements", namespaces=namespace) != "arm64":
    raise SystemExit("The update feed must require Apple Silicon.")
enclosure = item.find("enclosure")
if enclosure is None or enclosure.get("url") != download_url:
    raise SystemExit("The update download URL is incorrect.")
if int(enclosure.get("length", "-1")) != os.path.getsize(archive_path):
    raise SystemExit("The update archive length is incorrect.")
signature = enclosure.get("{" + namespace["sparkle"] + "}edSignature")
if not signature:
    raise SystemExit("The update archive has no EdDSA signature.")
print(signature)
