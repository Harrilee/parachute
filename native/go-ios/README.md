# Local location acknowledgement patch

The existing go-ios CLI waits indefinitely after a successful `StartSimulateLocation` DTX reply without printing a success message. A still-running process is not proof that the request succeeded. The native map's success animation therefore needs an explicit acknowledgement.

`location-ack.patch` adds one structured `event=location-simulation-started` log entry immediately after that call returns without error. The event contains no coordinates or device identifier. No device protocols, dependency versions, tunnel behavior, or go-ios version are upgraded for native Parachute 1.0.0.

The source is pinned to `Harrilee/go-ios` commit `80ed9e1cb2c9dfd8af38efff54e0feaad6fe742b`, the inspected `v1.0.204` ref, and requires Go 1.24.4. The previously inspected local Electron `bin/ios` reported `local-build` with no embedded source revision. This pinned source commit is therefore not independently verified provenance for that old binary. Its SHA-256 (`0d5d80df01f77b9c0532d6e95530ed07f7915159b0d363089038798ce8c80798`) and 26 embedded module records remain the comparison baseline; the records are checked in at `native/release/go-ios-dependencies.txt`.

Build on a fresh machine with Go 1.24.4 installed:

```sh
bash native/release/build-go-ios.sh "$(uname -m)" "$PWD/native/build/ios-native"
NATIVE_GO_IOS_BINARY="$PWD/native/build/ios-native" bash native/build.sh
```

For Intel cross-compilation, use `x86_64` as the helper's first argument. By default, `native/build.sh` calls this builder directly and writes `native/build/ios-with-ack` plus its `.build-info.txt`. Neither path requires an Electron checkout or the old `bin/ios`. The [transition implementation](https://github.com/Harrilee/parachute/tree/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05) retains its separate published-binary provisioning.

Set `GO_IOS_SOURCE_DIR` to a cached source checkout if available. The builder clones it into temporary build space and never patches the original checkout; otherwise it fetches the pinned commit. Fresh builds may download the already-locked modules. `GOTOOLCHAIN=local` and `-mod=readonly` prevent implicit compiler or dependency upgrades. Tracked module/workspace files and sums must remain unchanged, and embedded dependency records must exactly match the checked-in baseline manifest.

An output is reused only when its recorded source commit, patch and dependency-manifest hashes, compiler, historical baseline hash, target architecture, and actual output hash match. Metadata is parsed as plain data, never executed. A verified cache hit does not clone or build. The build-info file records those inputs and the output checksum; outputs live in ignored native build space.

The acknowledgement means the device service accepted the simulation request. It does not independently verify the phone's reported location. Native code associates the acknowledgement with the coordinates supplied to that subprocess and generates a new event identity for each successful attempt. True device simulation remains a separate validation step.
