#!/usr/bin/env python3
"""Test release process cleanup, ticket retries, package metadata and bridge provenance."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile


RELEASE = Path(__file__).resolve().parents[2] / "scripts/release"
RUNNER = RELEASE / "process.py"
HELPER = RELEASE / "package.sh"


def load_tool(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stapler = load_tool("release_process", RUNNER)
bridge = load_tool("bridge_source", RELEASE / "fetch-bridge-source.py")


class PackagingProcessTests(unittest.TestCase):
    def run_command(self, root, source, timeout=5):
        log = Path(root) / 'command.log'
        result = subprocess.run([sys.executable, str(RUNNER), 'run', '--timeout', str(timeout), '--log', str(log),
                                 '--', sys.executable, '-c', source], capture_output=True, text=True, timeout=15)
        return result, log.read_text()

    def test_success_and_output_are_retained(self):
        with tempfile.TemporaryDirectory() as root:
            result, log = self.run_command(root, "print('packaging output')")
            self.assertEqual(result.returncode, 0)
            self.assertIn('packaging output', log)
            self.assertEqual(json.loads(log.splitlines()[-1])['exitCode'], 0)

    def test_nonzero_exit_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            result, log = self.run_command(root, "import sys; print('package failed'); sys.exit(7)")
            self.assertEqual(result.returncode, 7)
            self.assertIn('package failed', log)

    def test_timeout_kills_own_group_and_preserves_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            with tempfile.TemporaryDirectory() as root:
                child_marker = Path(root) / 'child-survived'
                source = ('import signal,subprocess,sys,time; '
                          'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                          'subprocess.Popen([sys.executable,"-c",'
                          + repr('import os,time,pathlib; print("childpid=" + str(os.getpid()), flush=True); time.sleep(7); pathlib.Path(' + repr(str(child_marker)) + ').touch()')
                          + ']); time.sleep(30)')
                result, log = self.run_command(root, source, timeout=0.2)
                self.assertEqual(result.returncode, 124)
                self.assertIn('Timed-out process:', log)
                self.assertIsNone(unrelated.poll())
                child_pid = next(line.split('=', 1)[1] for line in log.splitlines() if line.startswith('childpid='))
                child_status = subprocess.run(['ps', '-o', 'stat=', '-p', child_pid], text=True, capture_output=True).stdout.strip()
                self.assertTrue(not child_status or child_status.startswith('Z'), child_status)
                self.assertFalse(child_marker.exists())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)


def response(code=0, output="The validate action worked!"):
    return subprocess.CompletedProcess([], code, output.encode())


NETWORK = 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'


class StaplerRetryTests(unittest.TestCase):
    def invoke(self, responses, operation="validate"):
        with patch.object(stapler.subprocess, "run", side_effect=responses) as run, \
                patch.object(stapler.time, "sleep") as sleep, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = stapler.run_stapler(operation, "/tmp/app with spaces.app")
        return status, run, sleep

    def test_success_requires_one_call_and_preserves_argument_array(self):
        status, run, sleep = self.invoke([response()])
        self.assertEqual(status, 0)
        self.assertEqual(run.call_args.args[0], ["xcrun", "stapler", "validate", "/tmp/app with spaces.app"])
        self.assertEqual(run.call_args.kwargs["timeout"], 120)
        sleep.assert_not_called()

    def test_transient_network_retries_staple_then_requires_real_success(self):
        status, run, sleep = self.invoke([response(68, NETWORK), response()], "staple")
        self.assertEqual(status, 0)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(5)

    def test_repeated_network_error_stops_after_three_attempts(self):
        status, run, sleep = self.invoke([response(68, NETWORK)] * 3)
        self.assertEqual(status, 68)
        self.assertEqual(run.call_count, 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [5, 15])

    def test_invalid_ticket_or_signature_does_not_retry(self):
        for code, output in [(68, "Could not validate ticket"),
                             (65, "The signature is invalid"),
                             (68, 'Error Domain=NSURLErrorDomain Code=-1202 "Certificate untrusted"'),
                             (65, NETWORK)]:
            with self.subTest(code=code, output=output):
                status, run, sleep = self.invoke([response(code, output)])
                self.assertEqual(status, code)
                self.assertEqual(run.call_count, 1)
                sleep.assert_not_called()

    def test_network_failure_followed_by_invalid_ticket_fails_closed(self):
        status, run, sleep = self.invoke([response(68, NETWORK), response(65, "Invalid ticket")])
        self.assertEqual(status, 65)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(5)

    def test_deadline_fails_instead_of_claiming_success(self):
        status, run, sleep = self.invoke([subprocess.TimeoutExpired(["xcrun"], 120, output=b"partial")])
        self.assertEqual(status, 124)
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()


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
                    "CFBundleVersion": "1000000", "CFBundleShortVersionString": "1.0.0"}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            package = root / "component.pkg"
            subprocess.run(["bash", str(HELPER), "component", str(app), str(package), info["CFBundleIdentifier"], "1.0.0"],
                           check=True, capture_output=True, text=True, timeout=30)
            requirements = root / "requirements.plist"
            requirements.write_bytes(plistlib.dumps({"os": ["14.0"], "arch": ["arm64"], "home": False}))
            product = root / "product.pkg"
            subprocess.run(["productbuild", "--package", str(package), "--product", str(requirements),
                            "--identifier", info["CFBundleIdentifier"] + ".installer", "--version", "1.0.0",
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
            self.assertEqual(metadata.attrib["version"], "1.0.0")
            self.assertEqual(metadata.findall("./relocate/bundle"), [])
            self.assertEqual(Path(metadata.find("bundle").attrib["path"]), Path("Parachute.app"))
            installed_info = expanded / "Payload" / "Parachute.app" / "Contents" / "Info.plist"
            self.assertEqual(installed_info.read_bytes(), (contents / "Info.plist").read_bytes())
            self.assertTrue(executable.exists(), "Packaging must retain the source application")


COMMIT = "a" * 40


class BridgeSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="bridge-mach-o-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binaries = {}
        for architecture, machine in [("arm64", "arm64"), ("x64", "x86_64")]:
            output = Path(cls.temporary.name) / architecture
            subprocess.run(["xcrun", "clang", "-target", machine + "-apple-macos14.0", "-c",
                            "-x", "c", "-", "-o", str(output)], input=b"int fixture(void) { return 0; }",
                           check=True, capture_output=True, timeout=30)
            cls.binaries[architecture] = output.read_bytes()

    def fixture(self, root, architecture="arm64", info=None, app_arch=None, helper_arch=None):
        archive = root / f"Parachute-darwin-{architecture}-0.3.9.zip"
        metadata = dict(CFBundleIdentifier="com.electron.parachute", CFBundleShortVersionString="0.3.9")
        metadata.update(info or {})
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("Parachute.app/Contents/Info.plist", plistlib.dumps(metadata))
            output.writestr("Parachute.app/Contents/MacOS/Parachute", self.binaries[app_arch or architecture])
            output.writestr("Parachute.app/Contents/Resources/ios", self.binaries[helper_arch or architecture])
        pins = {"version": "0.3.9", "sourceCommit": COMMIT,
                "archives": {architecture: {"sha256": bridge.sha256(archive)}}}
        pins_path = root / "pins.json"
        pins_path.write_text(json.dumps(pins))
        return archive, pins_path

    def test_missing_or_invalid_pins_fail_before_network(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(bridge, "api") as request:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "pins are not configured"):
                bridge.fetch("arm64", root, root / "missing.json")
            _, pins_path = self.fixture(root)
            valid = json.loads(pins_path.read_text())
            for key, value in [("version", "0.3.8"), ("sourceCommit", "main"),
                               ("archives", {}), ("archives", {"arm64": {"sha256": "bad"}})]:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    pins_path.write_text(json.dumps(dict(valid, **{key: value})))
                    bridge.fetch("arm64", root, pins_path)
            with self.assertRaisesRegex(ValueError, "Unsupported"):
                bridge.fetch("other", root, pins_path)
            request.assert_not_called()

    def test_only_stable_release_at_pinned_commit_can_download(self):
        stable = {"tag_name": "v0.3.9", "draft": False, "prerelease": False}
        cases = [(dict(stable, **{key: value}), COMMIT) for key, value in
                 [("draft", True), ("prerelease", True), ("tag_name", "v1.0.0"), ("draft", None)]]
        cases.append((stable, "b" * 40))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, pins = self.fixture(root)
            for release, commit in cases:
                with self.subTest(release=release, commit=commit), \
                        patch.object(bridge, "api", side_effect=[release, {"object": {"type": "commit", "sha": commit}}]), \
                        patch.object(bridge.subprocess, "run") as download, self.assertRaises(ValueError):
                    bridge.fetch("arm64", root, pins)
                download.assert_not_called()

    def test_published_download_records_verified_release_eligibility(self):
        real_run = subprocess.run
        for architecture in ("arm64", "x64"):
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive, pins = self.fixture(root, architecture)
                downloads = []
                def execute(arguments, **kwargs):
                    if arguments[0] == "gh":
                        downloads.append((arguments, kwargs))
                        return subprocess.CompletedProcess(arguments, 0)
                    return real_run(arguments, **kwargs)
                with patch.object(bridge, "api", side_effect=[
                        {"tag_name": "v0.3.9", "draft": False, "prerelease": False},
                        {"object": {"type": "commit", "sha": COMMIT}}]), \
                        patch.object(bridge.subprocess, "run", side_effect=execute), contextlib.redirect_stdout(io.StringIO()):
                    bridge.fetch(architecture, root, pins)
                self.assertEqual(downloads[0][0], ["gh", "release", "download", "v0.3.9", "--repo", bridge.REPOSITORY,
                                                   "--pattern", archive.name, "--dir", str(root)])
                self.assertEqual(downloads[0][1]["timeout"], 300)
                self.assertEqual(len(downloads), 1)
                self.assertEqual(json.loads((root / "bridge-source.json").read_text()), {
                    "source": "published-release", "releaseEligible": True, "tag": "v0.3.9",
                    "sourceCommit": COMMIT, "architecture": architecture, "archive": archive.name,
                    "sha256": bridge.sha256(archive)})

    def test_archive_hash_identity_version_and_both_architectures_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, _ = self.fixture(root)
            expected = bridge.sha256(archive)
            archive.write_bytes(archive.read_bytes() + b"tampered")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                bridge.verify_archive(archive, expected, "arm64")
            for change, error in [({"info": {"CFBundleIdentifier": "other.app"}}, ValueError),
                                  ({"info": {"CFBundleShortVersionString": "0.3.8"}}, ValueError),
                                  ({"app_arch": "x64"}, subprocess.CalledProcessError),
                                  ({"helper_arch": "x64"}, subprocess.CalledProcessError)]:
                with self.subTest(change=change), self.assertRaises(error):
                    archive, _ = self.fixture(root, **change)
                    bridge.verify_archive(archive, bridge.sha256(archive), "arm64")

    def test_annotated_release_tag_resolves_to_the_pinned_commit(self):
        with patch.object(bridge, "api", side_effect=[
                {"object": {"type": "tag", "sha": "c" * 40}},
                {"object": {"type": "commit", "sha": COMMIT}}]) as request:
            self.assertEqual(bridge.release_commit(), COMMIT)
        self.assertEqual([call.args[0] for call in request.call_args_list],
                         ["git/ref/tags/v0.3.9", "git/tags/" + "c" * 40])

    def test_invalid_or_cyclic_release_tag_is_bounded_and_rejected(self):
        for reference, expected_calls in [({"type": "tree", "sha": COMMIT}, 1),
                                           ({"type": "tag", "sha": COMMIT}, 6)]:
            with self.subTest(reference=reference), patch.object(bridge, "api", return_value={"object": reference}) as request:
                with self.assertRaisesRegex(ValueError, "does not resolve"):
                    bridge.release_commit()
                self.assertEqual(request.call_count, expected_calls)


if __name__ == "__main__":
    unittest.main()
