#!/usr/bin/env python3
"""Fetch the pinned, published 0.3.9 bridge; never build Electron here."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
import plistlib


REPOSITORY = "Harrilee/parachute"
DEFAULT_PINS = Path(__file__).with_name("bridge-release-pins.json")


def api(path):
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}"],
                            capture_output=True, text=True, check=True, timeout=60)
    return json.loads(result.stdout)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_archive(path, expected_hash, architecture):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash or "") or sha256(path) != expected_hash:
        raise ValueError("Bridge ZIP SHA-256 does not match the reviewed source")
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory(prefix="bridge-architecture-") as temporary:
        info = plistlib.loads(archive.read("Parachute.app/Contents/Info.plist"))
        if info.get("CFBundleIdentifier") != "com.electron.parachute" or info.get("CFBundleShortVersionString") != "0.3.9":
            raise ValueError("Bridge ZIP is not Parachute 0.3.9")
        machine = {"arm64": "arm64", "x64": "x86_64"}[architecture]
        for member in ("MacOS/Parachute", "Resources/ios"):
            executable = Path(temporary) / Path(member).name
            executable.write_bytes(archive.read("Parachute.app/Contents/" + member))
            subprocess.run(["/usr/bin/lipo", str(executable), "-verify_arch", machine],
                           check=True, capture_output=True, timeout=30)


def release_commit():
    reference = api("git/ref/tags/v0.3.9")["object"]
    for _ in range(5):
        if reference.get("type") == "commit":
            return reference["sha"]
        if reference.get("type") != "tag":
            break
        reference = api(f"git/tags/{reference['sha']}")["object"]
    raise ValueError("Published bridge tag does not resolve to a commit")


def fetch(architecture, output, pins_path=DEFAULT_PINS):
    if architecture not in ("arm64", "x64"):
        raise ValueError("Unsupported bridge architecture")
    if not pins_path.is_file():
        raise ValueError("Published 0.3.9 SHA-256 pins are not configured")
    pins = json.loads(pins_path.read_text())
    if pins.get("version") != "0.3.9" or not re.fullmatch(r"[0-9a-f]{40}", pins.get("sourceCommit", "")):
        raise ValueError("Published bridge pins have invalid version or commit")
    expected_hash = pins.get("archives", {}).get(architecture, {}).get("sha256")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash or ""):
        raise ValueError("Published bridge architecture lacks a reviewed SHA-256")
    release = api("releases/tags/v0.3.9")
    if release.get("draft") is not False or release.get("prerelease") is not False or release.get("tag_name") != "v0.3.9":
        raise ValueError("Bridge 0.3.9 must be published as a stable release")
    if release_commit() != pins["sourceCommit"]:
        raise ValueError("Published bridge tag differs from the reviewed commit")
    output.mkdir(parents=True, exist_ok=True)
    filename = f"Parachute-darwin-{architecture}-0.3.9.zip"
    archive = output / filename
    subprocess.run(["gh", "release", "download", "v0.3.9", "--repo", REPOSITORY,
                    "--pattern", filename, "--dir", str(output)], check=True, timeout=300)
    verify_archive(archive, expected_hash, architecture)
    evidence = {"source": "published-release", "releaseEligible": True,
                "tag": "v0.3.9", "sourceCommit": pins["sourceCommit"]}
    evidence.update(architecture=architecture, archive=filename, sha256=sha256(archive))
    (output / "bridge-source.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", required=True, choices=("arm64", "x64"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pins", type=Path, default=DEFAULT_PINS)
    args = parser.parse_args()
    fetch(args.architecture, args.output, args.pins)


if __name__ == "__main__":
    main()
