# Parachute app icon

`AppIcon.icon` is an editable Apple Icon Composer document. Its five SVG layers
retain Parachute's cyan/blue canopy and green location pin. The enclosure, lighting,
glass and appearance adaptation are rendered by the system, not baked into a PNG.

- Default: pale blue enclosure and the original brand colors.
- Dark: system dark enclosure and brighter suspension lines and pin.
- Mono: distinct neutral tones for the canopy, lines and pin. macOS uses this
  rendition for Clear and Tinted in both light and dark appearances; the user's
  selected tint is not hard-coded into the icon.

`native/build.sh` calls `compile-icon.py` before signing. With Xcode 26 or later,
it compiles the document to `Assets.car`, validates the Default/Dark/Mono image stacks, merges
the compiler's icon metadata into `Info.plist`, and installs the generated ICNS
fallback for macOS 14/15 and decodes that ICNS to check its classic image entries.
The fallback is generated from the new composition; it is not a promise to display
the original legacy artwork on older systems. An existing asset catalog is never
silently replaced.
Release builds require the layered catalog. Local Command Line Tools-only builds
explicitly warn and retain the existing static `icon.icns`; such a preview does
**not** validate Dark/Clear/Tinted support in the Dock.

To render actual Apple previews without changing system appearance settings:

```sh
ICTOOL='/path/to/Icon Composer.app/Contents/Executables/ictool' \
  bash native/icons/render-previews.sh
```

For an early CI compiler check without building or launching Parachute:

```sh
bash native/icons/test-compile.sh /path/to/icon-evidence
```

This preserves the actual catalog, generated metadata/ICNS, and `assetutil` JSON.
The validator accepts the observed Apple catalog encodings `UIAppearanceLight` /
`UIAppearanceDark` and `NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua`, plus
`ISAppearanceTintable` for Mono. Apple Maps on macOS 26 uses the first pair;
Calendar and Calculator use the second. The presence of those stacks verifies
the compiled variants, not the Dock's runtime rendering or background materials.

To require full icon compilation for a local staging app:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 native/icons/compile-icon.py /path/to/unsigned/Parachute.app --required
```

The original `assets/app-icon-glass.png`, `assets/logo.svg` and `icon.icns` are
preserved. Do not flatten the new document to an ICNS and treat that as equivalent
to shipping the layered catalog.

Validation: all six appearances rendered successfully with Apple's signed Icon
Composer 1.2 `ictool`; the missing-compiler release failure and local fallback
paths were exercised. Actual `actool` compilation and Dock appearance switching
remain to be verified on a full Xcode build host (this machine has Command Line
Tools only). Rendered preview backgrounds are baked by the preview renderer; the
runtime Clear material must be checked using the compiled catalog.

Reference: [Apple's Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

The release CI compiles icons on macOS 26 with Xcode 26.2. On macOS 15, that compiler crashes in AssetCatalogAgent because its rendering frameworks lack the required CoreMedia symbols; a newer SDK alone is insufficient. This build-host requirement does not change the application deployment target or the ICNS fallback for older systems.
