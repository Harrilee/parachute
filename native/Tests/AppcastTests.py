#!/usr/bin/env python3
"""Isolated artifact checks; generates disposable keys, never uses Keychain or publishes."""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

NATIVE = Path(__file__).resolve().parents[1]
GENERATOR = NATIVE / "updater/generate-appcast.py"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main():
    with tempfile.TemporaryDirectory(prefix="parachute-appcast-tests-") as folder:
        root = Path(folder)
        os.chmod(root, 0o700)
        source = root / "TestKey.swift"
        source.write_text('''import CryptoKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: folder.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("private.txt").path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: folder.appendingPathComponent("public.txt"), atomically: true, encoding: .utf8)
''')
        binary = root / "key-fixture"
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(root)], check=True)
        private_key = (root / "private.txt").read_bytes()
        public_key = (root / "public.txt").read_text()
        cpu = "arm64" if os.uname().machine == "arm64" else "x64"
        info = {
            "CFBundleIdentifier": "com.electron.parachute",
            "CFBundleVersion": "400000", "CFBundleShortVersionString": "0.4.0",
            "CFBundleExecutable": "Parachute", "CFBundleName": "Parachute",
            "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
            "ParachuteUpdatesEnabled": True, "SUPublicEDKey": public_key,
            "SUFeedURL": f"https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-{cpu}.xml",
        }
        archive = root / f"Parachute-native-{cpu}-0.4.0.zip"
        output = root / f"appcast-{cpu}.xml"

        def create_archive():
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("Parachute.app/Contents/Info.plist", plistlib.dumps(info))
                for name in ("Contents/MacOS/Parachute", "Contents/Resources/ios"):
                    zipped.write(binary, "Parachute.app/" + name)

        def run(expected_success=True, key=private_key, extras=()):
            result = subprocess.run([
                str(GENERATOR), "--archive", str(archive), "--architecture", cpu,
                "--version", "0.4.0", "--build", "400000",
                "--download-base-url", "https://example.invalid/test/",
                "--public-key-file", str(root / "public.txt"), "--output", str(output), *extras,
            ], input=key, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert (result.returncode == 0) == expected_success, result.stderr.decode()
            assert private_key not in result.stdout + result.stderr, "Private test key leaked to diagnostics"

        create_archive()
        run(extras=("--sha256", hashlib.sha256(archive.read_bytes()).hexdigest()))
        original = output.read_bytes()
        parsed = ET.parse(output)
        assert parsed.findtext(f"channel/item/{{{SPARKLE}}}version") == "400000"
        assert parsed.findtext(f"channel/item/{{{SPARKLE}}}minimumSystemVersion") == "14.0.0"
        assert parsed.find("channel/item/enclosure").get("length") == str(archive.stat().st_size)
        assert b"edSignature" in original
        run(False, extras=("--sha256", "0" * 64))
        for key, wrong_value in (
            ("CFBundleVersion", "999"),
            ("CFBundleIdentifier", "li.haorui.Parachute.NativePrototype"),
            ("ParachuteUpdatesEnabled", False),
            ("SUFeedURL", "https://example.invalid/wrong-architecture.xml"),
            ("LSMinimumSystemVersion", "15.0"),
        ):
            old = info[key]
            info[key] = wrong_value
            create_archive()
            run(False)
            info[key] = old
        create_archive()
        run(False, key=b"invalid-test-key")
        alternate = root / "alternate"
        alternate.mkdir(mode=0o700)
        subprocess.run([str(binary), str(alternate)], check=True)
        run(False, key=(alternate / "private.txt").read_bytes())
        assert output.read_bytes() == original, "Failed validation replaced an existing signed feed"
        print("Passed signed appcast generation and 8 rejection checks; disposable keys removed on exit")


if __name__ == "__main__":
    main()
