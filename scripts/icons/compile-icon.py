#!/usr/bin/env python3
"""Compile the layered macOS icon into an unsigned staging app, before signing."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def validate_appearances(records: list) -> list:
    stacks = [record for record in records
              if record.get("AssetType") == "IconImageStack"
              and record.get("Name") == "AppIcon"]
    if not stacks or any(stack.get("LayerCount", 0) <= 0 for stack in stacks):
        raise SystemExit("Compiled catalog has no nonempty layered AppIcon image stack.")
    appearances = {stack.get("Appearance") for stack in stacks}
    # Both encodings occur in Apple's shipping macOS catalogs: Maps uses the UI
    # names, while Calendar/Calculator use the NS Aqua names. Mono is the shared
    # ISAppearanceTintable stack; Clear/Tinted are runtime renderings of it.
    has_default = bool(appearances & {"UIAppearanceLight", "NSAppearanceNameAqua"})
    has_dark = bool(appearances & {"UIAppearanceDark", "NSAppearanceNameDarkAqua"})
    if not (has_default and has_dark and "ISAppearanceTintable" in appearances):
        raise SystemExit("Compiled AppIcon is missing Default, Dark, or Mono layers: "
                         + repr(sorted(str(value) for value in appearances)))
    return [{key: stack[key] for key in ("Name", "Appearance", "LayerCount", "RenditionName")
             if key in stack} for stack in stacks]


def compile_icon(app: Path, required: bool, report: Path | None = None) -> None:
    icon_dir = Path(__file__).resolve().parents[2] / "Resources"
    app = app.resolve()
    info_path = app / "Contents/Info.plist"
    resources = app / "Contents/Resources"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if not resources.is_dir():
        raise SystemExit("Icon destination must be an existing staging app bundle.")

    result = subprocess.run(
        ["xcrun", "--find", "actool"], capture_output=True, text=True
    )
    if result.returncode:
        if required:
            raise SystemExit(
                "Liquid Glass release icons require Xcode 26 or later (actool). "
                "Select full Xcode with DEVELOPER_DIR; Command Line Tools alone "
                "cannot compile Icon Composer assets."
            )
        # A local CLI-only preview remains buildable without pretending it supports
        # the layered appearances. The release path never falls back silently.
        fallback = icon_dir / "AppIcon.icns"
        shutil.copyfile(fallback, resources / "AppIcon.icns")
        info.pop("CFBundleIconName", None)
        info["CFBundleIconFile"] = "AppIcon"
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream)
        print("warning: actool unavailable; preview uses the legacy static icon. "
              "Dark/Clear/Tinted require a full Xcode build.", flush=True)
        return

    # Compile separately so a failure cannot leave a partially written catalog in
    # the bundle. Keep the compiler-generated icon metadata, including its actual
    # fallback ICNS filename, rather than guessing it from the source filename.
    with tempfile.TemporaryDirectory(prefix="parachute-icon-") as temporary:
        output = Path(temporary)
        partial = output / "icon-info.plist"
        subprocess.run([
            result.stdout.strip(), str(icon_dir / "AppIcon.icon"),
            "--compile", str(output), "--app-icon", "AppIcon",
            "--include-all-app-icons", "--output-partial-info-plist", str(partial),
            "--platform", "macosx", "--target-device", "mac",
            "--minimum-deployment-target", info["LSMinimumSystemVersion"],
            "--errors", "--warnings", "--notices",
            "--output-format", "human-readable-text",
        ], check=True)
        with partial.open("rb") as stream:
            generated = plistlib.load(stream)
        if generated.get("CFBundleIconName") != "AppIcon":
            raise SystemExit("actool did not generate the layered AppIcon metadata.")
        catalog = output / "Assets.car"
        if report:
            # Retain compiler output even if an older host's assetutil cannot
            # decode the new format, so CI evidence can be inspected on macOS 26.
            report.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(catalog, report.parent / "Assets.car")
            shutil.copyfile(partial, report.with_suffix(".partial-info.plist"))
        assetutil = subprocess.check_output(["xcrun", "--find", "assetutil"], text=True).strip()
        records = json.loads(subprocess.check_output([assetutil, "--info", str(catalog)], text=True))
        if report:
            report.with_suffix(".assetutil.json").write_text(json.dumps(records, indent=2) + "\n")
        stacks = validate_appearances(records)
        icon_file = generated.get("CFBundleIconFile", "")
        if not icon_file or Path(icon_file).name != icon_file:
            raise SystemExit("Unexpected fallback icon filename from actool.")
        if not icon_file.endswith(".icns"):
            icon_file += ".icns"
        fallback = output / icon_file
        if not fallback.is_file():
            raise SystemExit("actool did not produce a backward-compatible ICNS.")
        # Decode the generated fallback to prove it contains usable classic icon
        # images; this does not claim it has been displayed on an older macOS.
        iconset = output / "Fallback.iconset"
        subprocess.run(["/usr/bin/iconutil", "--convert", "iconset", "--output", str(iconset), str(fallback)], check=True)
        fallback_images = sorted(path.name for path in iconset.glob("*.png"))
        if not fallback_images:
            raise SystemExit("Generated ICNS has no decodable fallback images.")
        if (resources / "Assets.car").exists():
            raise SystemExit("Existing Assets.car must be compiled together with AppIcon.")
        shutil.copyfile(catalog, resources / catalog.name)
        shutil.copyfile(fallback, resources / fallback.name)
        info.update(generated)
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream)
        evidence = {"actool": result.stdout.strip(), "assetutil": assetutil,
                    "minimumDeploymentTarget": info["LSMinimumSystemVersion"],
                    "stacks": stacks, "fallbackFile": icon_file, "fallbackImages": fallback_images}
        if report:
            report.write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps(evidence, sort_keys=True), flush=True)
        print("Installed layered AppIcon and legacy ICNS fallback before signing.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--required", action="store_true")
    parser.add_argument("--report", type=Path, help="Optional compiler/catalog validation evidence file")
    args = parser.parse_args()
    compile_icon(args.app, args.required or os.environ.get("NATIVE_RELEASE") == "1", args.report)
