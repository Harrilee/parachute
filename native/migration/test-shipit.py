#!/usr/bin/env python3
"""Exercise genuine Squirrel replacement in fresh temporary copies, without launch.

This is a component test, not the original updater's HTTP/approval/relaunch flow.
No destination application argument is accepted. No application main is executed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import stat
import subprocess
import sys
import tempfile
import uuid
import zipfile


LEGACY_ARCHIVES = {
    "e9912087e25a2a8b3d23f0f5abc3df055fd744d20d8ef990809279bff6aa629e": "arm64",
    "3c64a40f42c66c678ddfcc6bdb881380ca6971b23740fe7817d475f0b2d9dc6a": "x64",
}
BUNDLE_ID = "com.electron.parachute"
SHIPIT = Path("Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt")


def run(arguments, **kwargs):
    result = subprocess.run(arguments, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} exited {result.returncode}: {result.stderr.strip()}")
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_hash(app):
    """Compare bundle bytes and symlink targets; Squirrel may clear quarantine xattrs."""
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            record = [relative, "symlink", os.readlink(path)]
        elif path.is_file():
            record = [relative, "file", stat.S_IMODE(path.stat().st_mode), sha256(path)]
        else:
            continue
        digest.update(json.dumps(record, ensure_ascii=True).encode() + b"\n")
    return digest.hexdigest()


def unpack(archive, destination):
    """Reject path escapes before allowing ditto to preserve framework symlinks."""
    symlinks = set()
    entries = []
    with zipfile.ZipFile(archive) as package:
        for entry in package.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError(f"Unsafe archive path: {entry.filename}")
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = package.read(entry).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(str(path.parent), target))
                if target.startswith("/") or resolved == ".." or resolved.startswith("../"):
                    raise ValueError(f"Unsafe archive symlink: {entry.filename}")
                symlinks.add(path)
            elif stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"Unsupported archive entry: {entry.filename}")
            entries.append(path)
    for path in entries:
        if any(parent in symlinks for parent in path.parents):
            raise ValueError(f"Archive writes through a symlink: {path}")
    destination.mkdir()
    run(["/usr/bin/ditto", "--noextattr", "-x", "-k", str(archive), str(destination)])
    apps = list(destination.glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Expected exactly one top-level application in the ZIP")
    for path in destination.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(destination):
            raise ValueError(f"Extracted symlink escapes staging: {path}")
    return apps[0]


def metadata(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Application identity does not match the published app")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    signature = run(["/usr/bin/codesign", "-d", "-r-", str(app)])
    requirement_lines = (signature.stdout + signature.stderr).splitlines()
    requirement = next(line.removeprefix("designated => ") for line in requirement_lines
                       if line.startswith("designated => "))
    if "YCP6FXQDL5" not in requirement:
        raise ValueError("Application is not signed by the published Developer ID team")
    return {
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "bundleID": info["CFBundleIdentifier"],
        "requirement": requirement,
        "bundleSHA256": tree_hash(app),
    }


def test_chain(legacy, candidates, report_directory):
    archive_digest = sha256(legacy)
    if archive_digest not in LEGACY_ARCHIVES:
        raise ValueError("Legacy ZIP is not an exact published Parachute 0.3.8 archive")
    if report_directory.exists():
        raise ValueError("Report directory must not already exist")
    report_directory.mkdir(parents=True)
    report = {
        "scope": "Genuine Squirrel bundle replacement only; application launch disabled",
        "notTested": ["HTTP feed selection", "download/extraction by the updater", "user approval",
                      "automatic application relaunch", "application/device behavior", "OS compatibility"],
        "legacyArchiveSHA256": archive_digest,
        "architecture": LEGACY_ARCHIVES[archive_digest],
        "steps": [],
    }
    try:
        # /private/tmp avoids cloud-file-provider metadata changing code signatures.
        with tempfile.TemporaryDirectory(prefix="parachute-shipit-", dir="/private/tmp") as temp:
            root = Path(temp).resolve()
            target = unpack(legacy, root / "installed")
            initial = metadata(target)
            if initial["version"] != "0.3.8":
                raise ValueError("Published initial version is not 0.3.8")
            report["initial"] = initial
            for index, archive in enumerate(candidates, 1):
                current = metadata(target)
                update = unpack(archive, root / f"update-{index}")
                incoming = metadata(update)
                run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
                     "=" + current["requirement"], str(update)])
                # Execute the helper from the currently installed version, copied
                # away before its original path is replaced. Never run its main.
                runner = root / f"runner-{index}" / "Parachute.app"
                runner.parent.mkdir()
                run(["/usr/bin/ditto", "--noextattr", str(target), str(runner)])
                helper = runner / SHIPIT
                if not helper.is_file() or not os.access(helper, os.X_OK):
                    raise ValueError("Current app has no genuine Squirrel installer")
                # The native compatibility launcher must never be used as an installer.
                if not (runner / "Contents/Frameworks/Electron Framework.framework").exists():
                    raise ValueError("Only an Electron application's installer may run")
                domain = f"com.electron.parachute.migration-test.{uuid.uuid4()}"
                state = root / f"request-{index}.json"
                state.write_text(json.dumps({
                    "updateBundleURL": update.as_uri(),
                    "targetBundleURL": target.as_uri(),
                    "bundleIdentifier": BUNDLE_ID,
                    "launchAfterInstallation": False,
                    "useUpdateBundleName": False,
                }))
                inode_before = target.stat().st_ino
                try:
                    try:
                        process = subprocess.run([str(helper), domain, str(state)],
                                                 capture_output=True, text=True, timeout=60)
                    except subprocess.TimeoutExpired as error:
                        output = (error.stdout or b"") + (error.stderr or b"")
                        (report_directory / f"shipit-{index}.log").write_bytes(output)
                        raise RuntimeError(f"ShipIt step {index} exceeded 60 seconds") from error
                    (report_directory / f"shipit-{index}.log").write_text(process.stdout + process.stderr)
                    if process.returncode != 0:
                        raise RuntimeError(f"ShipIt step {index} failed with exit {process.returncode}")
                finally:
                    # This unique test domain did not exist before this invocation.
                    for prefix in ([], ["-currentHost"]):
                        subprocess.run(["/usr/bin/defaults", *prefix, "delete", domain],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                installed = metadata(target)
                if installed != incoming or target.stat().st_ino == inode_before:
                    raise RuntimeError("Installed bundle does not match the candidate or was not replaced")
                report["steps"].append({
                    "fromVersion": current["version"], "toVersion": incoming["version"],
                    "candidateArchiveSHA256": sha256(archive), "installerSHA256": sha256(helper),
                    "installed": installed, "replaced": True, "launched": False,
                })
        report["passed"] = True
    except BaseException as error:
        report["passed"] = False
        report["error"] = str(error)
        raise
    finally:
        (report_directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {len(report['steps'])} isolated replacement step(s); report: {report_directory}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy", type=Path, required=True, help="Exact signed published v0.3.8 ZIP")
    parser.add_argument("--report-directory", type=Path, required=True, help="New directory for logs/report")
    parser.add_argument("candidates", nargs="+", type=Path, help="Signed update ZIPs, in installation order")
    options = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This test requires macOS")
    test_chain(options.legacy.resolve(), [path.resolve() for path in options.candidates],
               options.report_directory.resolve())
