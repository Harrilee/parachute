#!/usr/bin/env python3
"""Inspect an unsigned fixture package without installing or launching it."""

from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


HELPER = Path(__file__).with_name("build-component.sh")


class ComponentPackageTests(unittest.TestCase):
    def test_payload_has_fixed_applications_destination_and_no_relocation(self):
        with tempfile.TemporaryDirectory(prefix="parachute-pkg-test-") as directory:
            root = Path(directory)
            app = root / "Parachute.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            executable = contents / "MacOS" / "Fixture"
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
            info = {"CFBundleIdentifier": "test.parachute.fixed-destination", "CFBundleName": "Parachute",
                    "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture",
                    "CFBundleVersion": "400000", "CFBundleShortVersionString": "0.4.0"}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            package = root / "component.pkg"
            subprocess.run(["bash", str(HELPER), str(app), str(package), info["CFBundleIdentifier"], "0.4.0"],
                           check=True, capture_output=True, text=True, timeout=30)
            requirements = root / "requirements.plist"
            requirements.write_bytes(plistlib.dumps({"os": ["14.0"], "arch": ["arm64"], "home": False}))
            product = root / "product.pkg"
            subprocess.run(["productbuild", "--package", str(package), "--product", str(requirements),
                            "--identifier", info["CFBundleIdentifier"] + ".installer", "--version", "0.4.0",
                            str(product)], check=True, capture_output=True, text=True, timeout=30)
            product_expanded = root / "product-expanded"
            subprocess.run(["pkgutil", "--expand", str(product), str(product_expanded)],
                           check=True, capture_output=True, text=True, timeout=30)
            distribution = ET.parse(product_expanded / "Distribution").getroot()
            self.assertEqual(distribution.find("options").attrib["hostArchitectures"], "arm64")
            self.assertEqual(distribution.find("./volume-check/allowed-os-versions/os-version").attrib["min"], "14.0")
            packaged_metadata = ET.parse(next(product_expanded.glob("*.pkg/PackageInfo"))).getroot()
            self.assertEqual(packaged_metadata.attrib["install-location"], "/Applications")
            self.assertEqual(packaged_metadata.findall("./relocate/bundle"), [])
            expanded = root / "expanded"
            subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)],
                           check=True, capture_output=True, text=True, timeout=30)
            metadata = ET.parse(expanded / "PackageInfo").getroot()
            self.assertEqual(metadata.attrib["install-location"], "/Applications")
            self.assertEqual(metadata.attrib["identifier"], info["CFBundleIdentifier"])
            self.assertEqual(metadata.attrib["version"], "0.4.0")
            self.assertEqual(metadata.findall("./relocate/bundle"), [])
            self.assertEqual(Path(metadata.find("bundle").attrib["path"]), Path("Parachute.app"))
            installed_info = expanded / "Payload" / "Parachute.app" / "Contents" / "Info.plist"
            self.assertEqual(installed_info.read_bytes(), (contents / "Info.plist").read_bytes())
            self.assertTrue(executable.exists(), "Packaging must retain the source application")


if __name__ == "__main__":
    unittest.main()
