#!/usr/bin/env python3
"""Validate or promote existing native CI artifacts; never build or re-sign them."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

REPO = "Harrilee/parachute"
BUNDLE = "com.electron.parachute"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PUBLIC_KEY = Path(__file__).resolve().parents[1] / "updater/public-key.txt"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.check_output(list(args), text=True, stderr=subprocess.PIPE, timeout=300)


def api(path, optional=False):
    try:
        return json.loads(command("gh", "api", f"repos/{REPO}/{path}"))
    except subprocess.CalledProcessError as error:
        if optional and "(HTTP 404)" in error.stderr:
            return None
        raise


def release_for_tag(tag):
    # GitHub's tag endpoint can return 404 for drafts. Listing authenticated
    # releases includes drafts; inspect every page and reject duplicate tags.
    matches = []
    for page in range(1, 101):
        releases = api(f"releases?per_page=100&page={page}")
        matches.extend(release for release in releases if release.get("tag_name") == tag)
        require(len(matches) <= 1, "Multiple releases use the requested tag")
        if len(releases) < 100:
            return matches[0] if matches else None
    raise ValueError("Release listing exceeds the 100-page inspection limit")


def digest(path):
    with path.open("rb") as stream:
        return {"sha256": hashlib.file_digest(stream, "sha256").hexdigest(), "bytes": path.stat().st_size}


def validate_run(run, run_id, commit):
    for key, expected in {"id": int(run_id), "head_sha": commit, "status": "completed",
                          "conclusion": "success", "event": "workflow_dispatch",
                          "path": ".github/workflows/release.yml"}.items():
        require(run.get(key) == expected, f"Source run mismatch: {key}")
    for key in ("repository", "head_repository"):
        require(run.get(key, {}).get("full_name") == REPO, "Source must be this repository, not a fork")


def verify_signature(data, signature, key):
    raw_signature = base64.b64decode(signature, validate=True)
    require(len(key) == 32 and len(raw_signature) == 64, "Invalid Ed25519 key/signature length")
    with tempfile.TemporaryDirectory(prefix="parachute-public-signature-") as directory:
        root = Path(directory)
        (root / "key.der").write_bytes(bytes.fromhex("302a300506032b6570032100") + key)
        (root / "data").write_bytes(data)
        (root / "signature").write_bytes(raw_signature)
        command("openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey",
                str(root / "key.der"), "-rawin", "-in", str(root / "data"), "-sigfile", str(root / "signature"))


def validate_bundle(folder, arch, version, run_id, commit):
    stem = f"Parachute-native-{arch}-{version}"
    names = [stem + suffix for suffix in (".zip", ".pkg", "-SHA256SUMS.txt", "-manifest.json")]
    names += [f"appcast-{arch}.xml", f"electron-migration-{arch}.json"]
    files = {name: folder / name for name in names}
    require(all(p.is_file() and not p.is_symlink() for p in files.values()), "Missing or unsafe native release file")
    manifest = json.loads(files[stem + "-manifest.json"].read_text())
    machine = "arm64" if arch == "arm64" else "x86_64"
    for key, expected in {"sourceCommit": commit, "workflowRun": run_id, "version": version,
                          "bundleIdentifier": BUNDLE, "architecture": machine, "minimumMacOS": "14.0"}.items():
        require(str(manifest.get(key)) == expected, f"Native manifest mismatch: {key}")
    build = str(manifest.get("build", ""))
    require(re.fullmatch(r"[1-9][0-9]*", build), "Invalid native build number")
    archives = {stem + extension: digest(files[stem + extension]) for extension in (".zip", ".pkg")}
    require(manifest.get("artifacts") == archives, "Native archive hashes or lengths differ from manifest")
    rows = [line.split() for line in files[stem + "-SHA256SUMS.txt"].read_text().splitlines()]
    require(len(rows) == 2 and all(len(row) == 2 for row in rows), "Invalid checksum file")
    require({name: value for value, name in rows} == {n: d["sha256"] for n, d in archives.items()}, "Checksum mismatch")
    key = base64.b64decode(PUBLIC_KEY.read_text().strip(), validate=True)
    with zipfile.ZipFile(files[stem + ".zip"]) as archive:
        path = "Parachute.app/Contents/Info.plist"
        require(archive.namelist().count(path) == 1, "Expected one application Info.plist")
        info = plistlib.loads(archive.read(path))
        expected_info = {"CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": version,
                         "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0",
                         "SUFeedURL": f"https://raw.githubusercontent.com/{REPO}/main/updates/appcast-{arch}.xml",
                         "SUPublicEDKey": PUBLIC_KEY.read_text().strip(), "ParachuteUpdatesEnabled": True,
                         "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True}
        require(all(info.get(k) == v for k, v in expected_info.items()), "Native application metadata mismatch")
        for relative in ("Contents/MacOS/Parachute", "Contents/Resources/ios"):
            with archive.open("Parachute.app/" + relative) as stream:
                header = stream.read(8)
            require(header[:4] == b"\xcf\xfa\xed\xfe" and len(header) == 8 and
                    struct.unpack_from("<I", header, 4)[0] == (0x0100000C if arch == "arm64" else 0x01000007),
                    "Native executable architecture mismatch")
    feed = files[f"appcast-{arch}.xml"].read_bytes()
    trailer = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?$", feed)
    require(trailer and int(trailer[2]) == trailer.start(), "Invalid signed appcast trailer")
    verify_signature(feed[:trailer.start()], trailer[1], key)
    items = ET.fromstring(feed).findall("./channel/item")
    require(len(items) == 1, "Expected one reviewed appcast item")
    item, enclosure = items[0], items[0].find("enclosure")
    require(item.findtext(SPARKLE + "version") == build and item.findtext(SPARKLE + "shortVersionString") == version
            and item.findtext(SPARKLE + "minimumSystemVersion") == "14.0.0", "Appcast version/build/minimum OS mismatch")
    url = f"https://github.com/{REPO}/releases/download/v{version}/{stem}.zip"
    require(enclosure is not None and enclosure.get("url") == url and
            enclosure.get("length") == str(files[stem + ".zip"].stat().st_size), "Appcast archive URL/length mismatch")
    verify_signature(files[stem + ".zip"].read_bytes(), enclosure.get(SPARKLE + "edSignature", ""), key)
    migration = json.loads(files[f"electron-migration-{arch}.json"].read_text())
    updates = migration.get("releases", [])
    require(migration.get("currentRelease") == "1.0.0" and len(updates) == 1 and updates[0].get("version") == "1.0.0"
            and updates[0].get("updateTo", {}).get("version") == "1.0.0" and updates[0]["updateTo"].get("url") ==
            f"https://github.com/{REPO}/releases/download/v1.0.0/Parachute-native-{arch}-1.0.0.zip",
            "First-native migration feed must remain pinned to 1.0.0")
    return files, build


def collect(root, run_id, commit, version):
    validate_run(api(f"actions/runs/{run_id}"), run_id, commit)
    artifacts = api(f"actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    files, builds, eligible, artifact_ids = {}, set(), {}, {}
    def download(name):
        matches = [a for a in artifacts if a["name"] == name and not a["expired"]]
        require(len(matches) == 1, f"Expected one unexpired artifact: {name}")
        artifact = matches[0]
        require(artifact.get("workflow_run", {}).get("head_sha") == commit and
                artifact["workflow_run"].get("id") == int(run_id), "Artifact source mismatch")
        destination = root / name
        command("gh", "run", "download", run_id, "--repo", REPO, "--name", name, "--dir", str(destination))
        artifact_ids[name] = artifact["id"]
        return destination
    for arch in ("arm64", "x64"):
        folder = download(f"native-macos-{arch}-{version}")
        bundle, build = validate_bundle(folder, arch, version, run_id, commit)
        files.update(bundle)
        builds.add(build)
        evidence = download(f"migration-evidence-{arch}")
        sources, reports = list(evidence.rglob("bridge-source.json")), list(evidence.rglob("report.json"))
        require(len(sources) == len(reports) == 1, "Missing migration evidence")
        source, report = json.loads(sources[0].read_text()), json.loads(reports[0].read_text())
        steps = report.get("steps", [])
        require(source.get("architecture") == arch and report.get("passed") is True and report.get("architecture") == arch and steps and
                steps[-1].get("toVersion") == version and steps[-1].get("candidateArchiveSHA256") ==
                digest(bundle[f"Parachute-native-{arch}-{version}.zip"])["sha256"], "Migration evidence does not verify this native ZIP")
        eligible[arch] = source.get("releaseEligible") is True and source.get("source") == "published-release"
    require(len(builds) == 1, "Native architectures have different build numbers")
    provenance = {"repository": REPO, "sourceRun": run_id, "sourceCommit": commit, "version": version,
                  "build": builds.pop(), "artifactIds": artifact_ids, "releaseEligible": eligible,
                  "assets": {name: digest(path) for name, path in sorted(files.items())}}
    ledger = root / "release-provenance.json"
    ledger.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    files[ledger.name] = ledger
    return files, provenance


def check_tag(tag, commit):
    reference = api(f"git/ref/tags/{tag}", optional=True)
    if reference is None:
        return
    obj = reference["object"]
    for _ in range(5):
        if obj.get("type") == "commit":
            require(obj["sha"] == commit, "Release tag points to a different commit")
            return
        require(obj.get("type") == "tag", "Invalid release tag object")
        obj = api(f"git/tags/{obj['sha']}")["object"]
    raise ValueError("Release tag nesting limit exceeded")


def check_existing(release, files, marker, commit, root, complete):
    require(release.get("draft") is True and not release.get("prerelease"), "Refusing to modify a published/prerelease release")
    require(release.get("target_commitish") == commit and marker in (release.get("body") or ""), "Draft provenance mismatch")
    assets = release.get("assets", [])
    names = [asset["name"] for asset in assets]
    require(len(names) == len(set(names)) and set(names) <= set(files), "Unexpected or duplicate draft assets")
    if complete:
        require(set(names) == set(files), "Draft has missing assets; complete it with action=draft first")
    downloaded = Path(tempfile.mkdtemp(prefix="existing-release-", dir=root))
    if names:
        command("gh", "release", "download", release["tag_name"], "--repo", REPO, "--dir", str(downloaded))
    for name in names:
        require(digest(downloaded / name) == digest(files[name]), f"Refusing to overwrite changed draft asset: {name}")
    return set(files) - set(names)


def promote(action, files, provenance, root):
    version, commit = provenance["version"], provenance["sourceCommit"]
    tag = "v" + version
    check_tag(tag, commit)
    marker = f"<!-- native-source: {provenance['sourceRun']} {commit} {version} -->"
    release = release_for_tag(tag)
    if action == "publish":
        require(provenance["releaseEligible"] == {"arm64": True, "x64": True}, "Formal publication requires migration tests using the published bridge")
        comparison = api(f"compare/{commit}...main")
        require(comparison.get("merge_base_commit", {}).get("sha") == commit, "Formal publication source is not on main")
        require(release is not None, "Create and review a draft before publishing")
        check_existing(release, files, marker, commit, root, complete=True)
        command("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest")
    else:
        missing = check_existing(release, files, marker, commit, root, complete=False) if release else set(files)
        if release is None:
            notes = root / "release-notes.md"
            notes.write_text(f"Native Parachute {version} for macOS 14 or later.\n\n"
                             "Complete the release guide's manual acceptance checks before publishing. "
                             "Update feeds are activated separately after publication.\n\n" + marker + "\n")
            command("gh", "release", "create", tag, "--repo", REPO, "--draft", "--target", commit,
                    "--title", f"Parachute {version}", "--notes-file", str(notes))
        if missing:
            command("gh", "release", "upload", tag, "--repo", REPO, *[str(files[name]) for name in sorted(missing)])
    result = release_for_tag(tag)
    require(result is not None, "Release was not found after the operation")
    require(result.get("draft") is (action == "draft"), "Unexpected release state after operation")
    if action == "draft":
        check_existing(result, files, marker, commit, root, complete=True)
    check_tag(tag, commit)
    print(result["html_url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=("validate", "draft", "publish"), default="draft")
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--version", default="1.0.0")
    args = parser.parse_args()
    require(re.fullmatch(r"[1-9][0-9]*", args.source_run_id), "Invalid run ID")
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit), "Expected an exact 40-character source commit")
    require(re.fullmatch(r"[1-9][0-9]*\.[0-9]+\.[0-9]+", args.version), "Expected a native version >=1.0.0")
    with tempfile.TemporaryDirectory(prefix="parachute-native-publication-") as temporary:
        root = Path(temporary)
        files, provenance = collect(root, args.source_run_id, args.source_commit, args.version)
        print(json.dumps(provenance, indent=2, sort_keys=True), flush=True)
        if args.action != "validate":
            promote(args.action, files, provenance, root)


def error_message(error):
    detail = f"{error}\n{error.stderr.strip()}" if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name):
            detail = detail.replace(os.environ[name], "[redacted]")
    return detail[-6000:]


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        raise SystemExit(f"Native publication failed: {error_message(error)}")
