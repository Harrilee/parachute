# Parachute app icon

`AppIcon.icon` is an editable Apple Icon Composer document. Its five SVG layers retain the cyan/blue canopy and green location pin. The system renders enclosure, lighting, glass and appearance adaptation.

- Default: pale blue enclosure and original brand colors.
- Dark: system dark enclosure with brighter suspension lines and pin.
- Mono: distinct neutral canopy, lines and pin tones for Clear and Tinted appearances; no user tint is hard-coded.

`scripts/build.sh` calls `compile-icon.py` once before signing. Release builds require macOS 26 with Xcode 26.2 or later. The compiler produces `Assets.car`, validates the Default/Dark/Mono stacks, merges icon metadata into `Info.plist`, and generates and decodes the ICNS fallback for macOS 14/15. The build-host requirement does not raise the application's macOS 14 deployment target. An existing asset catalog is never silently replaced.

Local builds with only Command Line Tools warn and retain root `Resources/AppIcon.icns`; these do not validate layered appearance support. The generated fallback comes from the new composition. Preserve the original `docs/assets/app-icon-glass.png`, `Resources/AppIcon.icns`, editable icon layers and supplied preview images.

To render Apple's six previews without changing system appearance settings:

```sh
ICTOOL='/path/to/Icon Composer.app/Contents/Executables/ictool' \
  bash scripts/icons/render-previews.sh
```

To require compilation and retain evidence for a local unsigned app:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 scripts/icons/compile-icon.py /path/to/unsigned/Parachute.app \
    --required --report /path/to/icon-evidence/icon-validation.json
```

CI sets `NATIVE_ICON_REPORT` during the actual application build. Its `icon-evidence/` contains `Assets.car`, the validation report, `assetutil` records and partial metadata. The final app ZIP contains the generated ICNS and merged Info.plist. There is no separate icon probe build.

The validator accepts Default/Dark encodings `UIAppearanceLight` / `UIAppearanceDark` or `NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua`, plus `ISAppearanceTintable` for Mono. These checks establish compiled appearance data and a decodable fallback. Actual Dock appearance switching, older-system display and Clear blending remain runtime checks; preview backgrounds alone do not establish them.

Reference: [Apple's Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
