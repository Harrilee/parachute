# Local location acknowledgement patch

The existing go-ios CLI waits indefinitely after a successful `StartSimulateLocation` DTX reply without printing a success message. A still-running process is not proof that the request succeeded. The native map's success animation therefore needs an explicit acknowledgement.

`location-ack.patch` adds one structured `event=location-simulation-started` log entry immediately after that call returns without error. The event contains no coordinates or device identifier. No device protocols, dependency versions, tunnel behavior, or update versions are changed.

The source is pinned to `Harrilee/go-ios` commit `80ed9e1cb2c9dfd8af38efff54e0feaad6fe742b`, the inspected `v1.0.204` ref. The previous `bin/ios` reports `local-build` and has no embedded source revision, so this source commit must not be claimed as independently verified provenance for the old binary.

Build with the already-installed Go 1.24.4 and cached dependencies:

```sh
bash native/go-ios/build-with-ack.sh
```

For a locally cached source checkout, set `GO_IOS_SOURCE_DIR` to that checkout. The script clones it into temporary build space and never patches the original checkout. With no cache path, it fetches the pinned commit from the fork. Go module resolution runs offline with `-mod=readonly`; all tracked workspace/module manifests and sums must remain unchanged. The resulting executable’s embedded dependency records must also exactly match the original binary’s records. Missing cached modules cause a failure rather than an implicit dependency change.

The builder reuses an existing output only when its recorded source commit, patch hash, compiler, original binary hash, target architecture and actual output hash all match. Metadata is parsed as plain data, never executed. A verified cache hit does not clone or build.

Outputs are `native/build/ios-with-ack` and `native/build/ios-with-ack.build-info.txt`, both under ignored build space. The original repository `bin/ios` is never replaced and its checksum is checked after building. The build-info file records source, patch, compiler, and original/output checksums.

This acknowledgement means the device service accepted the simulation request. It does not collect or independently verify the phone's current location. Native code associates the acknowledgement with the coordinates supplied to that particular subprocess, and generates a new event identity for each successful attempt.
