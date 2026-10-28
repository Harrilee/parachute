#!/usr/bin/env python3
"""Validate a final ZIP, sign it, and write a signed architecture-specific feed.

The Sparkle private key is accepted only on stdin. It is never written to disk,
passed in command arguments, or included in captured error output.
"""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = ROOT.parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_parts(value):
    parts = str(value).split(".")
    require(1 <= len(parts) <= 3 and all(part.isdigit() for part in parts),
            "Invalid minimum macOS version.")
    return tuple(map(int, parts)) + (0,) * (3 - len(parts))


def architectures(header):
    magic = header[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        return {struct.unpack_from("<I", header, 4)[0]}
    if magic in (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        return {struct.unpack_from(">I", header, 4)[0]}
    endian = ">" if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") else "<"
    require(magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
                      b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"), "Expected a Mach-O binary.")
    count = struct.unpack_from(endian + "I", header, 4)[0]
    size = 32 if magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") else 20
    require(0 < count <= 16 and 8 + count * size <= len(header), "Invalid Mach-O architecture table.")
    return {struct.unpack_from(endian + "I", header, 8 + index * size)[0] for index in range(count)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=("arm64", "x64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--download-base-url", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--public-key-file", type=Path, default=PROJECT_ROOT / "Resources/Sparkle/public-key.txt")
    parser.add_argument("--sha256", help="Optional expected SHA-256 of the final notarized ZIP")
    parser.add_argument("--minimum-system-version", default="14.0.0")
    parser.add_argument("--notes", type=Path, help="Optional UTF-8 plain-text release notes")
    args = parser.parse_args()
    require(re.fullmatch(r"\d+\.\d+\.\d+", args.version) is not None, "Version must be major.minor.patch.")
    require(args.build.isdigit() and int(args.build) > 0, "Build must be a positive, monotonically increasing integer.")
    archive = args.archive.resolve(strict=True)
    require(archive.name == f"Parachute-native-{args.architecture}-{args.version}.zip",
            "Native ZIP name must not match the old Electron update service's macOS asset pattern.")
    require(args.output.name == f"appcast-{args.architecture}.xml", "Appcast filename must identify its architecture.")
    base = urlsplit(args.download_base_url)
    require(base.scheme == "https" and base.hostname and not base.username and not base.password
            and not base.query and not base.fragment, "Download base URL must be HTTPS without credentials or query parameters.")
    public_key = args.public_key_file.read_text().strip()
    require(len(base64.b64decode(public_key, validate=True)) == 32, "Invalid Sparkle public key.")
    feed_url = f"https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-{args.architecture}.xml"
    expected_cpu = 0x0100000C if args.architecture == "arm64" else 0x01000007
    with zipfile.ZipFile(archive) as zipped:
        infos = [name for name in zipped.namelist()
                 if name.endswith(".app/Contents/Info.plist") and not name.startswith("__MACOSX/")
                 and name.count("/") == 2]
        require(infos == ["Parachute.app/Contents/Info.plist"], "ZIP must contain one top-level Parachute.app.")
        info = plistlib.loads(zipped.read(infos[0]))
        for key, expected in {
            "CFBundleIdentifier": "com.electron.parachute",
            "CFBundleShortVersionString": args.version,
            "CFBundleVersion": args.build,
            "SUFeedURL": feed_url,
            "SUPublicEDKey": public_key,
            "ParachuteUpdatesEnabled": True,
        }.items():
            require(info.get(key) == expected, f"Archive Info.plist has an unexpected {key}.")
        require(version_parts(info.get("LSMinimumSystemVersion", "")) == version_parts(args.minimum_system_version),
                "Archive and appcast minimum macOS versions differ.")
        for binary in ("Contents/MacOS/Parachute", "Contents/Resources/ios"):
            with zipped.open("Parachute.app/" + binary) as file:
                require(expected_cpu in architectures(file.read(4096)), f"Architecture mismatch in {binary}.")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if args.sha256:
        require(digest == args.sha256.lower(), "Final archive SHA-256 mismatch.")

    # Do all public validation before reading or using the secret.
    key = sys.stdin.buffer.read(4097).strip()
    require(0 < len(key) <= 4096, "Provide the Sparkle private key on stdin.")
    environment = {name: value for name, value in os.environ.items() if name != "SPARKLE_PRIVATE_KEY"}
    distribution = Path(subprocess.check_output([str(ROOT / "fetch-sparkle.sh")], text=True, env=environment).strip())
    signer = distribution / "bin/sign_update"

    def sign(arguments):
        result = subprocess.run([str(signer), "--ed-key-file", "-", *map(str, arguments)], input=key,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        require(result.returncode == 0, "Sparkle signing or verification failed; private-key diagnostics were suppressed.")
        return result.stdout.decode().strip()

    signature = sign(["-p", archive])
    require(len(base64.b64decode(signature, validate=True)) == 64, "Sparkle returned an invalid signature.")
    # Verify against the checked-in public key, not merely the private key supplied
    # by CI, so a stale/wrong Secret cannot produce an unusable published feed.
    with tempfile.TemporaryDirectory(prefix="verify-update-", dir=PROJECT_ROOT / "build") as temporary:
        verifier = Path(temporary) / "verify-signature"
        subprocess.run(["xcrun", "swiftc", str(ROOT / "verify-signature.swift"), "-o", str(verifier)], check=True, env=environment)
        subprocess.run([str(verifier), str(args.public_key_file.resolve()), str(archive), signature], check=True, env=environment)

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = f"Parachute ({args.architecture})"
    ET.SubElement(channel, "link").text = "https://github.com/Harrilee/parachute"
    ET.SubElement(channel, "description").text = "Parachute native macOS updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Parachute {args.version}"
    ET.SubElement(item, "link").text = "https://github.com/Harrilee/parachute/releases"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = ".".join(map(str, version_parts(args.minimum_system_version)))
    if args.architecture == "arm64":
        ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    if args.notes:
        ET.SubElement(item, "description", {f"{{{SPARKLE}}}descriptionFormat": "plain-text"}).text = args.notes.read_text()
    ET.SubElement(item, "enclosure", {
        "url": args.download_base_url.rstrip("/") + "/" + quote(archive.name),
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss, space="  ")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".appcast-", suffix=".xml", dir=args.output.parent, delete=False) as file:
        temporary_feed = Path(file.name)
    try:
        ET.ElementTree(rss).write(temporary_feed, encoding="utf-8", xml_declaration=True)
        sign(["-p", temporary_feed])
        sign(["--verify", temporary_feed])
        ET.parse(temporary_feed)
        os.replace(temporary_feed, args.output)
    finally:
        temporary_feed.unlink(missing_ok=True)
    print(f"Signed {args.output} for build {args.build}; archive SHA-256 {digest}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, struct.error, subprocess.SubprocessError) as error:
        print(f"Appcast generation failed: {error}", file=sys.stderr)
        sys.exit(1)
