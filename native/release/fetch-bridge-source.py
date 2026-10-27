#!/usr/bin/env python3
"""Fetch the separately reviewed 0.3.9 bridge; never build Electron here."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile
import plistlib


REPOSITORY = "Harrilee/parachute"
WORKFLOW = ".github/workflows/release.yml"
BRANCHES = {"feat/harrli/electron-transition-0.3.9", "main"}
DEFAULT_PINS = Path(__file__).with_name("bridge-release-pins.json")


def api(path):
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}"],
                            capture_output=True, text=True, check=True, timeout=60)
    return json.loads(result.stdout)


def validate_run(run, run_id, commit):
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("A bridge CI run requires its exact approved 40-character commit")
    expected = {"id": int(run_id), "status": "completed", "conclusion": "success",
                "head_sha": commit, "path": WORKFLOW, "event": "workflow_dispatch"}
    for key, value in expected.items():
        if run.get(key) != value:
            raise ValueError(f"Bridge CI provenance mismatch: {key}")
    if run.get("head_branch") not in BRANCHES:
        raise ValueError("Bridge CI source branch is not the reviewed transition branch or main")
    for key in ("repository", "head_repository"):
        if run.get(key, {}).get("full_name") != REPOSITORY:
            raise ValueError("Bridge CI must originate from the same repository, not a fork")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_archive(path, expected_hash):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash or "") or sha256(path) != expected_hash:
        raise ValueError("Bridge ZIP SHA-256 does not match the reviewed source")
    with zipfile.ZipFile(path) as archive:
        info = plistlib.loads(archive.read("Parachute.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "com.electron.parachute" or info.get("CFBundleShortVersionString") != "0.3.9":
        raise ValueError("Bridge ZIP is not Parachute 0.3.9")


def verify_ci_manifest(manifest, archive, architecture, run_id, commit):
    expected = {"sourceCommit": commit, "workflowRun": run_id, "version": "0.3.9",
                "bundleID": "com.electron.parachute", "architecture": architecture}
    for key, value in expected.items():
        if str(manifest.get(key)) != value:
            raise ValueError(f"Bridge artifact manifest mismatch: {key}")
    details = manifest.get("artifacts", {}).get(archive.name, {})
    if details.get("bytes") != archive.stat().st_size:
        raise ValueError("Bridge artifact length does not match its manifest")
    verify_archive(archive, details.get("sha256"))


def release_commit():
    reference = api("git/ref/tags/v0.3.9")["object"]
    for _ in range(5):
        if reference.get("type") == "commit":
            return reference["sha"]
        if reference.get("type") != "tag":
            break
        reference = api(f"git/tags/{reference['sha']}")["object"]
    raise ValueError("Published bridge tag does not resolve to a commit")


def fetch(architecture, output, run_id="", commit="", pins_path=DEFAULT_PINS):
    if bool(run_id) != bool(commit):
        raise ValueError("Supply both bridge_run_id and bridge_commit, or neither for a published release")
    output.mkdir(parents=True, exist_ok=True)
    filename = f"Parachute-darwin-{architecture}-0.3.9.zip"
    archive = output / filename
    if run_id:
        if not re.fullmatch(r"[1-9][0-9]*", run_id):
            raise ValueError("Bridge run ID must be numeric")
        run = api(f"actions/runs/{run_id}")
        validate_run(run, run_id, commit)
        subprocess.run(["gh", "run", "download", run_id, "--repo", REPOSITORY,
                        "--name", f"electron-bridge-macos-{architecture}-0.3.9", "--dir", str(output)],
                       check=True, timeout=300)
        manifest = json.loads((output / f"bridge-{architecture}-manifest.json").read_text())
        verify_ci_manifest(manifest, archive, architecture, run_id, commit)
        evidence = {"source": "reviewed-ci", "releaseEligible": False, "runID": run_id,
                    "sourceCommit": commit}
    else:
        # This file is intentionally absent until 0.3.9 is actually published
        # and its architecture-specific hashes are reviewed in a follow-up.
        if not pins_path.is_file():
            raise ValueError("Published 0.3.9 SHA-256 pins are not configured; use the reviewed bridge CI run for PR validation")
        pins = json.loads(pins_path.read_text())
        if pins.get("version") != "0.3.9" or not re.fullmatch(r"[0-9a-f]{40}", pins.get("sourceCommit", "")):
            raise ValueError("Published bridge pins have invalid version or commit")
        release = api("releases/tags/v0.3.9")
        if release.get("draft") or release.get("prerelease") or release.get("tag_name") != "v0.3.9":
            raise ValueError("Bridge 0.3.9 must be published as a stable release")
        if release_commit() != pins["sourceCommit"]:
            raise ValueError("Published bridge tag differs from the reviewed commit")
        hashes = pins.get("archives", {})
        expected_hash = hashes.get(architecture, {}).get("sha256")
        if not re.fullmatch(r"[0-9a-f]{64}", expected_hash or ""):
            raise ValueError("Published bridge architecture lacks a reviewed SHA-256")
        subprocess.run(["gh", "release", "download", "v0.3.9", "--repo", REPOSITORY,
                        "--pattern", filename, "--dir", str(output)], check=True, timeout=300)
        verify_archive(archive, expected_hash)
        evidence = {"source": "published-release", "releaseEligible": True,
                    "tag": "v0.3.9", "sourceCommit": pins["sourceCommit"]}
    evidence.update(architecture=architecture, archive=filename, sha256=sha256(archive))
    (output / "bridge-source.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", required=True, choices=("arm64", "x64"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--expected-commit", default="")
    parser.add_argument("--pins", type=Path, default=DEFAULT_PINS)
    args = parser.parse_args()
    fetch(args.architecture, args.output, args.run_id, args.expected_commit, args.pins)


if __name__ == "__main__":
    main()
