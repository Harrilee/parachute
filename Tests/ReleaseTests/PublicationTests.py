#!/usr/bin/env python3
"""Native publication safeguards, using disposable keys and mocked GitHub writes."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

SPEC = importlib.util.spec_from_file_location("publication", Path(__file__).resolve().parents[2] / "scripts/release/publish.py")
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)
COMMIT, RUN, VERSION, BUILD = "a" * 40, "123", "1.0.1", "1000001"
STEM = "Parachute-native-arm64-1.0.1"


class PublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix="publication-test-keys-")
        cls.key_root = Path(cls.keys.name)
        cls.private = cls.key_root / "private.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(cls.private)], check=True, capture_output=True)
        public = subprocess.check_output(["openssl", "pkey", "-in", str(cls.private), "-pubout", "-outform", "DER"])
        cls.public = cls.key_root / "public.txt"
        cls.public.write_text(base64.b64encode(public[-32:]).decode() + "\n")

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="publication-test-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.key_patch = patch.object(publication, "PUBLIC_KEY", self.public)
        self.key_patch.start()
        self.addCleanup(self.key_patch.stop)
        info = {"CFBundleIdentifier": publication.BUNDLE, "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": BUILD, "LSMinimumSystemVersion": "14.0",
                "SUFeedURL": f"https://raw.githubusercontent.com/{publication.REPO}/main/updates/appcast-arm64.xml",
                "SUPublicEDKey": self.public.read_text().strip(), "ParachuteUpdatesEnabled": True,
                "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True}
        self.archive = self.root / (STEM + ".zip")
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Parachute.app/Contents/Info.plist", plistlib.dumps(info))
            for name in ("Contents/MacOS/Parachute", "Contents/Resources/ios"):
                archive.writestr("Parachute.app/" + name, b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C))
        (self.root / (STEM + ".pkg")).write_bytes(b"fixture package")
        self.manifest = {"sourceCommit": COMMIT, "workflowRun": RUN, "version": VERSION, "build": BUILD,
                         "bundleIdentifier": publication.BUNDLE, "architecture": "arm64", "minimumMacOS": "14.0"}
        self.write_manifest()
        (self.root / "electron-migration-arm64.json").write_text(json.dumps({"currentRelease": "1.0.0",
            "releases": [{"version": "1.0.0", "updateTo": {"version": "1.0.0",
                "url": f"https://github.com/{publication.REPO}/releases/download/v1.0.0/Parachute-native-arm64-1.0.0.zip"}}]}))
        self.write_feed()

    def write_manifest(self):
        self.manifest["artifacts"] = {STEM + suffix: publication.digest(self.root / (STEM + suffix)) for suffix in (".zip", ".pkg")}
        (self.root / (STEM + "-manifest.json")).write_text(json.dumps(self.manifest))
        (self.root / (STEM + "-SHA256SUMS.txt")).write_text("".join(
            f"{data['sha256']}  {name}\n" for name, data in self.manifest["artifacts"].items()))

    def sign(self, data):
        source, signature = self.root / "sign-input", self.root / "signature"
        source.write_bytes(data)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.private), "-rawin",
                        "-in", str(source), "-out", str(signature)], check=True, capture_output=True)
        return base64.b64encode(signature.read_bytes()).decode()

    def write_feed(self, url=None, build=BUILD, length=None):
        tree = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(tree, "channel"), "item")
        for key, value in (("version", build), ("shortVersionString", VERSION), ("minimumSystemVersion", "14.0.0")):
            ET.SubElement(item, publication.SPARKLE + key).text = value
        ET.SubElement(item, "enclosure", {"url": url or f"https://github.com/{publication.REPO}/releases/download/v{VERSION}/{STEM}.zip",
            "length": str(self.archive.stat().st_size if length is None else length),
            publication.SPARKLE + "edSignature": self.sign(self.archive.read_bytes())})
        prefix = ET.tostring(tree, encoding="utf-8", xml_declaration=True)
        trailer = f"<!-- sparkle-signatures:\nedSignature: {self.sign(prefix)}\nlength: {len(prefix)}\n-->\n"
        (self.root / "appcast-arm64.xml").write_bytes(prefix + trailer.encode())

    def validate(self):
        return publication.validate_bundle(self.root, "arm64", VERSION, RUN, COMMIT)

    def public_files(self):
        files, _ = self.validate()
        for extension in (".zip", ".pkg"):
            name = f"Parachute-native-x64-{VERSION}{extension}"
            destination = self.root / name
            shutil.copyfile(self.root / (STEM + extension), destination)
            files[name] = destination
        return publication.public_release_files(self.root, files, VERSION)

    def test_signed_native_artifacts_pass_without_rewriting(self):
        before = (self.root / "appcast-arm64.xml").read_bytes()
        files, build = self.validate()
        self.assertEqual(len(files), 6)
        self.assertEqual(build, BUILD)
        self.assertEqual((self.root / "appcast-arm64.xml").read_bytes(), before)

    def test_public_files_are_only_four_installers_and_one_complete_checksum_list(self):
        files = self.public_files()
        installers = {f"Parachute-native-{arch}-{VERSION}{extension}"
                      for arch in ("arm64", "x64") for extension in (".zip", ".pkg")}
        self.assertEqual(set(files), installers | {"SHA256SUMS.txt"})
        rows = [line.split() for line in files["SHA256SUMS.txt"].read_text().splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual([name for _, name in rows], sorted(installers))
        self.assertEqual({name: value for value, name in rows},
                         {name: publication.digest(files[name])["sha256"] for name in installers})
        self.assertTrue((self.root / "appcast-arm64.xml").exists())
        with self.assertRaisesRegex(ValueError, "Missing native installer"):
            publication.public_release_files(self.root, {STEM + ".zip": self.archive}, VERSION)

    def test_later_release_must_not_retarget_the_first_native_migration_feed(self):
        path = self.root / "electron-migration-arm64.json"
        path.write_text(path.read_text().replace("1.0.0", VERSION))
        with self.assertRaisesRegex(ValueError, "pinned to 1.0.0"):
            self.validate()

    def test_public_draft_resumes_without_internal_attachments_or_overwrites(self):
        files = self.public_files()
        provenance = {"version": VERSION, "sourceCommit": COMMIT, "sourceRun": RUN}
        state, writes = {}, []
        remote = self.root / "remote"
        remote.mkdir()
        def github_command(*args):
            operation = args[2]
            if operation == "create":
                notes = Path(args[args.index("--notes-file") + 1]).read_text()
                state.update(draft=True, prerelease=False, target_commitish=COMMIT, body=notes,
                             assets=[], tag_name="v" + VERSION, html_url="https://example.invalid/release")
                writes.append(operation)
            elif operation == "upload":
                for value in args[6:]:
                    source = Path(value)
                    shutil.copyfile(source, remote / source.name)
                    state["assets"].append({"name": source.name})
                writes.append(operation)
            elif operation == "download":
                destination = Path(args[args.index("--dir") + 1])
                for source in remote.iterdir():
                    shutil.copyfile(source, destination / source.name)
            else:
                self.fail(f"Unexpected GitHub write: {args}")
            return ""
        with patch.object(publication, "check_tag"), \
                patch.object(publication, "release_for_tag", side_effect=lambda tag: state or None), \
                patch.object(publication, "command", side_effect=github_command), contextlib.redirect_stdout(io.StringIO()):
            publication.promote("draft", files, provenance, self.root)
            self.assertEqual({asset["name"] for asset in state["assets"]}, set(files))
            publication.promote("draft", files, provenance, self.root)
            self.assertEqual(writes, ["create", "upload"])
            (remote / "SHA256SUMS.txt").write_text("tampered")
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                publication.promote("draft", files, provenance, self.root)
            self.assertEqual(writes, ["create", "upload"])

    def test_internal_output_survives_validation_and_cannot_reuse_an_existing_directory(self):
        output = self.root / "publication-evidence"
        def collect(root, *args):
            (root / "release-provenance.json").write_text('{"internal":true}')
            return {}, {"sourceRun": RUN}
        arguments = ["publish.py", "--action", "validate", "--source-run-id", RUN,
                     "--source-commit", COMMIT, "--version", VERSION, "--output", str(output)]
        with patch.object(sys, "argv", arguments), patch.object(publication, "collect", side_effect=collect) as validate, \
                patch.object(publication, "promote") as promote, contextlib.redirect_stdout(io.StringIO()):
            publication.main()
            self.assertTrue((output / "release-provenance.json").is_file())
            with self.assertRaises(FileExistsError):
                publication.main()
            self.assertEqual(validate.call_count, 1)
            promote.assert_not_called()

    def test_source_run_rejects_failure_wrong_sha_workflow_or_fork(self):
        run = {"id": 123, "head_sha": COMMIT, "status": "completed", "conclusion": "success",
               "event": "workflow_dispatch", "path": ".github/workflows/release.yml",
               "repository": {"full_name": publication.REPO}, "head_repository": {"full_name": publication.REPO}}
        publication.validate_run(run, RUN, COMMIT)
        for key, value in (("conclusion", "failure"), ("head_sha", "b" * 40), ("path", "other.yml"),
                           ("event", "pull_request"), ("head_repository", {"full_name": "other/fork"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                publication.validate_run(dict(run, **{key: value}), RUN, COMMIT)

    def test_wrong_manifest_version_architecture_and_identity_are_rejected(self):
        for key, value in (("version", "1.0.2"), ("architecture", "x86_64"), ("bundleIdentifier", "other"), ("workflowRun", "456")):
            original = self.manifest[key]
            self.manifest[key] = value
            self.write_manifest()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate()
            self.manifest[key] = original

    def test_archive_or_checksum_tampering_is_rejected(self):
        package = self.root / (STEM + ".pkg")
        package.write_bytes(b"changed package")
        with self.assertRaisesRegex(ValueError, "hashes"):
            self.validate()
        self.write_manifest()
        (self.root / (STEM + "-SHA256SUMS.txt")).write_text("wrong checksum")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.validate()

    def test_signed_appcast_wrong_url_build_or_length_is_rejected(self):
        for override in ({"url": "https://example.com/wrong.zip"}, {"build": "2"}, {"length": 1}):
            self.write_feed(**override)
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.validate()

    def test_appcast_signature_tampering_is_rejected(self):
        feed = self.root / "appcast-arm64.xml"
        feed.write_bytes(feed.read_bytes().replace(b"<rss", b"<RSS", 1))
        with self.assertRaises(subprocess.CalledProcessError):
            self.validate()

    def test_changed_or_published_draft_is_never_overwritten(self):
        files, _ = self.validate()
        release = {"draft": False, "prerelease": False, "target_commitish": COMMIT, "body": "marker", "assets": []}
        with patch.object(publication, "command") as write:
            with self.assertRaisesRegex(ValueError, "published"):
                publication.check_existing(release, files, "marker", COMMIT, self.root, complete=False)
            release.update(draft=True, assets=[{"name": "unexpected.zip"}])
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                publication.check_existing(release, files, "marker", COMMIT, self.root, complete=False)
            write.assert_not_called()

    def test_missing_draft_assets_block_publish_and_allow_non_overwriting_resume(self):
        files, _ = self.validate()
        release = {"draft": True, "prerelease": False, "target_commitish": COMMIT, "body": "marker", "assets": []}
        self.assertEqual(publication.check_existing(release, files, "marker", COMMIT, self.root, complete=False), set(files))
        with self.assertRaisesRegex(ValueError, "missing"):
            publication.check_existing(release, files, "marker", COMMIT, self.root, complete=True)

    def test_existing_asset_with_different_bytes_is_never_overwritten(self):
        name = STEM + ".zip"
        release = {"draft": True, "prerelease": False, "target_commitish": COMMIT,
                   "body": "marker", "tag_name": "v1.0.0", "assets": [{"name": name}]}
        def download(*args):
            self.assertEqual(args[:3], ("gh", "release", "download"))
            destination = Path(args[args.index("--dir") + 1])
            (destination / name).write_bytes(b"different existing asset")
        with patch.object(publication, "command", side_effect=download) as network:
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                publication.check_existing(release, {name: self.archive}, "marker", COMMIT, self.root, complete=True)
            self.assertEqual(network.call_count, 1)

    def test_existing_tag_must_resolve_to_the_same_commit(self):
        with patch.object(publication, "api", return_value={"object": {"type": "commit", "sha": "b" * 40}}):
            with self.assertRaisesRegex(ValueError, "different commit"):
                publication.check_tag("v1.0.0", COMMIT)

    def test_draft_lookup_uses_paginated_listing_when_tag_endpoint_would_return_404(self):
        draft = {"id": 456, "tag_name": "v1.0.0", "draft": True, "target_commitish": COMMIT}
        def github(path, **kwargs):
            if path == "releases/tags/v1.0.0":
                raise subprocess.CalledProcessError(1, ["gh", "api"], stderr="gh: Not Found (HTTP 404)")
            if path == "releases?per_page=100&page=1":
                return [{"tag_name": f"v2.0.{index}"} for index in range(100)]
            if path == "releases?per_page=100&page=2":
                return [draft]
            self.fail(f"Unexpected API path: {path}")
        with patch.object(publication, "api", side_effect=github):
            self.assertEqual(publication.release_for_tag("v1.0.0"), draft)

    def test_duplicate_release_tags_are_rejected(self):
        with patch.object(publication, "api", return_value=[{"tag_name": "v1.0.0"}] * 2):
            with self.assertRaisesRegex(ValueError, "Multiple releases"):
                publication.release_for_tag("v1.0.0")

    def test_subprocess_errors_include_diagnostics_but_redact_tokens(self):
        error = subprocess.CalledProcessError(1, ["gh", "api"], stderr="HTTP 403 diagnostic private-token")
        with patch.dict(os.environ, {"GH_TOKEN": "private-token"}):
            message = publication.error_message(error)
        self.assertIn("HTTP 403 diagnostic", message)
        self.assertNotIn("private-token", message)

    def test_publish_requires_eligible_migration_and_main_ancestry_before_any_write(self):
        provenance = {"version": VERSION, "sourceCommit": COMMIT, "sourceRun": RUN,
                      "releaseEligible": {"arm64": False, "x64": True}}
        with patch.object(publication, "check_tag"), patch.object(publication, "release_for_tag", return_value={}), \
                patch.object(publication, "api", return_value={}), \
                patch.object(publication, "command") as write:
            with self.assertRaisesRegex(ValueError, "published bridge"):
                publication.promote("publish", {}, provenance, self.root)
            provenance["releaseEligible"]["arm64"] = True
            with self.assertRaisesRegex(ValueError, "not on main"):
                publication.promote("publish", {}, provenance, self.root)
            write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
