#!/usr/bin/env python3
"""Run one isolated Sparkle download/install/relaunch test (requires a GUI login).

Uses an ad-hoc signed native fixture app, disposable EdDSA key, unique bundle ID,
and loopback-only feed. Does not launch Parachute, access a device or production
feed/key, or change production preferences. Results remain under native/build.
"""
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

NATIVE = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def main():
    root = NATIVE / "build" / ("sparkle-upgrade-" + str(uuid.uuid4()))
    root.mkdir(parents=True, mode=0o700)
    bundle_id = "li.haorui.Parachute.UpdaterTest." + uuid.uuid4().hex
    distribution = Path(subprocess.check_output([str(NATIVE / "updater/fetch-sparkle.sh")], text=True).strip())
    server_root = root / "server"
    server_root.mkdir()
    requests = []

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, format, *arguments):
            requests.append(format % arguments)

    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(server_root)))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    events = []
    result = {"bundleID": bundle_id, "resultDirectory": str(root), "success": False}
    app = root / "Installed" / "Sparkle Upgrade Fixture.app"
    try:
        with tempfile.TemporaryDirectory(prefix="sparkle-disposable-key-") as protected:
            secret_dir = Path(protected)
            os.chmod(secret_dir, 0o700)
            key_source = secret_dir / "Key.swift"
            key_source.write_text('''import CryptoKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: directory.appendingPathComponent("private"), atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("private").path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: directory.appendingPathComponent("public"), atomically: true, encoding: .utf8)
''')
            key_tool = secret_dir / "make-key"
            subprocess.run(["xcrun", "swiftc", str(key_source), "-o", str(key_tool)], check=True)
            subprocess.run([str(key_tool), str(secret_dir)], check=True)
            private_key = (secret_dir / "private").read_bytes()
            public_key = (secret_dir / "public").read_text()
            (root / "public-key.txt").write_text(public_key)
            app.joinpath("Contents/MacOS").mkdir(parents=True)
            app.joinpath("Contents/Frameworks").mkdir()
            subprocess.run(["ditto", str(distribution / "Sparkle.framework"), str(app / "Contents/Frameworks/Sparkle.framework")], check=True)
            compiler = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-F", str(distribution),
                        "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
            if os.environ.get("NATIVE_SDK_PATH"):
                compiler += ["-sdk", os.environ["NATIVE_SDK_PATH"]]
            compiler += [str(NATIVE / "Tests/SparkleUpgradeHarness.swift"), "-o", str(app / "Contents/MacOS/Fixture")]
            subprocess.run(compiler, check=True)
            info = {
                "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Fixture",
                "CFBundleName": "Sparkle Upgrade Fixture", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0",
                "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
                "SUFeedURL": f"http://127.0.0.1:{port}/appcast.xml", "SUPublicEDKey": public_key,
                "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
                "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
                "SUEnableSystemProfiling": False, "UpgradeTestDirectory": str(root),
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            }
            def write_info(path, value):
                (path / "Contents/Info.plist").write_bytes(plistlib.dumps(value))
            write_info(app, info)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            candidate = root / "Candidate" / app.name
            candidate.parent.mkdir()
            subprocess.run(["ditto", str(app), str(candidate)], check=True)
            info["CFBundleVersion"] = "2"
            info["CFBundleShortVersionString"] = "1.0.1"
            write_info(candidate, info)
            subprocess.run(["codesign", "--force", "--sign", "-", str(candidate)], check=True, capture_output=True)
            archive = server_root / "update.zip"
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(candidate), str(archive)], check=True)
            signer = distribution / "bin/sign_update"
            signature = subprocess.check_output([str(signer), "--ed-key-file", "-", "-p", str(archive)], input=private_key).decode().strip()
            feed = ET.Element("rss", {"version": "2.0"})
            channel = ET.SubElement(feed, "channel")
            ET.SubElement(channel, "title").text = "Isolated Sparkle upgrade test"
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = "Fixture 1.0.1"
            ET.SubElement(item, f"{{{SPARKLE}}}version").text = "2"
            ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = "1.0.1"
            ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0.0"
            ET.SubElement(item, "enclosure", {"url": f"http://127.0.0.1:{port}/update.zip",
                          "type": "application/octet-stream", "length": str(archive.stat().st_size),
                          f"{{{SPARKLE}}}edSignature": signature})
            feed_path = server_root / "appcast.xml"
            ET.ElementTree(feed).write(feed_path, encoding="utf-8", xml_declaration=True)
            subprocess.run([str(signer), "--ed-key-file", "-", "-p", str(feed_path)], input=private_key, check=True)
            private_key = b""
        # Disposable private key files are gone before the test app is launched.
        subprocess.run(["open", "-n", "-g", str(app)], check=True)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            log = root / "events.jsonl"
            if log.exists():
                events = [json.loads(line) for line in log.read_text().splitlines() if line]
                if any(event["event"] in ("relaunch-confirmed", "failed", "timeout") for event in events):
                    break
            time.sleep(0.2)
        installed_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        result["installedBuild"] = installed_info["CFBundleVersion"]
        result["requests"] = requests
        result["events"] = events
        result["success"] = installed_info["CFBundleVersion"] == "2" and any(
            event["event"] == "relaunch-confirmed" and event["version"] == "2" for event in events)
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"success": result["success"], "result": str(root / "result.json"),
                          "installedBuild": result["installedBuild"]}))
        if not result["success"]:
            raise RuntimeError("Sparkle installation/relaunch was not verified; see isolated result.json")
    finally:
        server.shutdown()
        server.server_close()
        # Only terminate a PID that wrote our log and still executes our fixture.
        for pid in {event["pid"] for event in events}:
            command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout.strip()
            if command.startswith(str(app / "Contents/MacOS/Fixture")):
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass
        subprocess.run(["defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cache = Path.home() / "Library/Caches" / bundle_id
        if cache.exists():
            shutil.rmtree(cache)


if __name__ == "__main__":
    main()
