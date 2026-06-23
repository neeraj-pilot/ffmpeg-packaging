# FFI Harness

Production mobile runtime harness code lives here. It links directly against
the packaged `ffmpeg_ffi` mobile artifact and exercises the public C ABI.

It should cover:

- normal completion
- command after normal completion
- overlapping command rejection
- cancellation
- command after cancellation
- immediate cancellation
- no callbacks after native execution returns
- no callbacks after Dart teardown
- no process-wide `SIGTERM` or `SIGPIPE` handler replacement during embedded
  execution
- no `-y` / `-n` overwrite state leakage across commands
- Photos-shaped HLS/AES single-file cancellation
- `ffmpeg_probe_media_json(...)` success and reentry

Run it after building the matching mobile artifacts:

```sh
tests/ffi_harness/run-mobile-harness.sh --android-device <adb-id>
tests/ffi_harness/run-mobile-harness.sh --ios-simulator <simulator-udid>
```

The native C harness does not run on physical iOS devices. Physical-device
coverage must come from a signed app or Flutter harness before release.
