#!/usr/bin/env python3
"""Check the compatibility launch protocol using a harmless, short-lived app.

Requires a macOS GUI session. Does not open or replace a real Parachute app.
"""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, capture_output=True, text=True, **kwargs)


def wait_for_lines(path, count):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        lines = path.read_text().splitlines() if path.exists() else []
        if len(lines) >= count:
            return lines
        time.sleep(0.05)
    raise RuntimeError(f"Did not observe {count} fixture launches")


with tempfile.TemporaryDirectory(prefix="parachute-launcher-test-", dir="/private/tmp") as temp:
    root = Path(temp).resolve()
    app = root / "Parachute Launcher Test.app"
    executable = app / "Contents/MacOS/Fixture"
    executable.parent.mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleIdentifier": "com.electron.parachute",
            "CFBundleName": "Parachute Launcher Test",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "LSUIElement": True,
        }, stream)
    source = root / "Fixture.m"
    source.write_text(r'''
#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <unistd.h>
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *marker = [NSBundle.mainBundle.bundlePath stringByAppendingString:@".launches"];
        int file = open(marker.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0600);
        if (file < 0) return 1;
        dprintf(file, "%d\n", getpid());
        close(file);
        // No window, network, location, updater, or device operations.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
        [NSApp run];
    }
}
''')
    sdk = os.environ.get("NATIVE_SDK_PATH") or run(["xcrun", "--show-sdk-path"]).stdout.strip()
    run(["xcrun", "clang", "-isysroot", sdk, "-fobjc-arc", "-framework", "AppKit",
         str(source), "-o", str(executable)])
    machine = run(["uname", "-m"]).stdout.strip()
    run(["bash", str(Path(__file__).resolve().parents[2] / "scripts/migration/build-launcher.sh"), str(app), machine])
    framework = app / "Contents/Frameworks/Squirrel.framework"
    for item in (framework, app):
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(item)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    helper = framework / "Versions/A/Resources/ShipIt"
    invalid = subprocess.run([str(helper), "___launch___", str(root / "Unrelated.app")],
                             capture_output=True, text=True, timeout=5)
    assert invalid.returncode == 65, "Launcher accepted an unrelated application"
    marker = Path(str(app) + ".launches")
    try:
        run(["/usr/bin/open", "-n", str(app)])
        first = wait_for_lines(marker, 1)
        run([str(helper), "___launch___", str(app)], timeout=35)
        instances = wait_for_lines(marker, 2)
        assert instances[0] == first[0] and len(set(instances)) == 2, "A new instance was not launched"
        print(json.dumps({"passed": True, "strictNestedSignature": True,
                          "rejectsUnrelatedApp": True, "launchesNewInstance": True,
                          "fixturePIDs": instances}))
    finally:
        # Terminate only executables at this newly created fixture's exact path.
        # The fixture also exits on its own after eight seconds.
        for value in marker.read_text().splitlines() if marker.exists() else []:
            process = subprocess.run(["/bin/ps", "-p", value, "-o", "comm="],
                                     capture_output=True, text=True)
            if process.stdout.strip() == str(executable):
                try:
                    os.kill(int(value), 15)
                except ProcessLookupError:
                    pass
