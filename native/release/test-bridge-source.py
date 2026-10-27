#!/usr/bin/env python3
"""Validate bridge provenance without network, devices, or signing credentials."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location("bridge_source", Path(__file__).with_name("fetch-bridge-source.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
COMMIT = "a" * 40


def valid_run():
    return {"id": 123, "status": "completed", "conclusion": "success", "head_sha": COMMIT,
            "path": bridge.WORKFLOW, "event": "workflow_dispatch",
            "head_branch": "feat/harrli/electron-transition-0.3.9",
            "repository": {"full_name": bridge.REPOSITORY}, "head_repository": {"full_name": bridge.REPOSITORY}}


class BridgeSourceTests(unittest.TestCase):
    def test_exact_successful_source_is_required(self):
        bridge.validate_run(valid_run(), "123", COMMIT)
        for field, value in [("status", "in_progress"), ("conclusion", "failure"),
                             ("head_sha", "b" * 40), ("path", ".github/workflows/other.yml"),
                             ("head_branch", "unreviewed"), ("event", "pull_request"),
                             ("head_repository", {"full_name": "other/parachute"})]:
            with self.subTest(field=field):
                run = valid_run()
                run[field] = value
                with self.assertRaises(ValueError):
                    bridge.validate_run(run, "123", COMMIT)

    def test_invalid_run_and_commit_arguments_are_rejected(self):
        for run_id, commit in [("123", "main"), ("../123", COMMIT), ("123", ""), ("0", COMMIT)]:
            with self.subTest(run_id=run_id, commit=commit), self.assertRaises(ValueError):
                bridge.validate_run(valid_run(), run_id, commit)

    def fixture(self, root):
        archive = root / "Parachute-darwin-arm64-0.3.9.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("Parachute.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.electron.parachute", "CFBundleShortVersionString": "0.3.9"}))
        manifest = {"sourceCommit": COMMIT, "workflowRun": "123", "version": "0.3.9",
                    "bundleID": "com.electron.parachute", "architecture": "arm64",
                    "artifacts": {archive.name: {"bytes": archive.stat().st_size, "sha256": bridge.sha256(archive)}}}
        return archive, manifest

    def test_manifest_hash_commit_and_length_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, manifest = self.fixture(Path(directory))
            bridge.verify_ci_manifest(manifest, archive, "arm64", "123", COMMIT)
            for key, value in [("sourceCommit", "b" * 40), ("version", "0.3.8"), ("architecture", "x64")]:
                bad = dict(manifest, **{key: value})
                with self.subTest(key=key), self.assertRaises(ValueError):
                    bridge.verify_ci_manifest(bad, archive, "arm64", "123", COMMIT)
            archive.write_bytes(archive.read_bytes() + b"tampered")
            with self.assertRaises(ValueError):
                bridge.verify_ci_manifest(manifest, archive, "arm64", "123", COMMIT)

    def test_reviewed_ci_evidence_never_claims_release_eligibility(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, manifest = self.fixture(root)
            (root / "bridge-arm64-manifest.json").write_text(json.dumps(manifest))
            with patch.object(bridge, "api", return_value=valid_run()), \
                    patch.object(bridge.subprocess, "run") as download, contextlib.redirect_stdout(io.StringIO()):
                bridge.fetch("arm64", root, "123", COMMIT)
            self.assertEqual(download.call_args.args[0][0:4], ["gh", "run", "download", "123"])
            self.assertIs(json.loads((root / "bridge-source.json").read_text())["releaseEligible"], False)

    def test_published_mode_requires_reviewed_pins_before_network(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(bridge, "api") as request:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "pins are not configured"):
                bridge.fetch("arm64", root, pins_path=root / "missing.json")
            request.assert_not_called()

    def test_partial_ci_source_selection_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "both"):
                bridge.fetch("arm64", Path(directory), "123", "")


if __name__ == "__main__":
    unittest.main()
