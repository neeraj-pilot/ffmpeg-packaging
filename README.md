# FFmpeg Packaging

Builds pinned FFmpeg artifacts for mobile and desktop consumers without
vendoring downloaded sources or generated outputs.

## What This Produces

| Platform | Artifact |
| --- | --- |
| Android | `dist/mobile/android/ffmpeg.aar` |
| iOS | `dist/mobile/ios/ffmpeg.xcframework` |
| macOS | `dist/desktop/darwin-universal/ffmpeg.tar.gz` |
| Linux | `dist/desktop/linux-x64/ffmpeg.tar.gz` |
| Windows | `dist/desktop/windows-x64/ffmpeg.zip` |

Artifact names, native library names, headers, and C symbols stay generic
FFmpeg names.

## Repository Layout

- `versions.env`: source and toolchain pins
- `scripts/`: fetch, build, package, and verify entrypoints
- `include/ffmpeg_ffi.h`: public mobile C ABI
- `src/`: mobile wrapper support code that does not patch FFmpeg
- `patches/`: reviewable FFmpeg source patches
- `docs/mobile-fftools-patch.md`: why the mobile `fftools` patch exists
- `tests/desktop_cli/`: desktop CLI media verification
- `tests/ffi_harness/`: native mobile runtime harness

Generated files are written outside the repo by default:

```text
../ffmpeg-packaging-test/
```

Override with `FFMPEG_PACKAGING_TEST_ROOT` when needed.

## Build Locally

```sh
scripts/fetch-sources.sh

scripts/build-mobile.sh android-arm64
scripts/build-mobile.sh android-armv7
scripts/verify-mobile.sh --target android-arm64 --target android-armv7

scripts/build-mobile.sh ios-device-arm64
scripts/build-mobile.sh ios-sim-arm64
scripts/verify-mobile.sh --target ios-device-arm64 --target ios-sim-arm64

scripts/build-desktop-cli.sh desktop-darwin-universal
scripts/build-desktop-cli.sh desktop-linux-x64
scripts/build-desktop-cli.sh desktop-windows-x64
```

Use `--help` on individual scripts for target-specific options.

## CI And Releases

`.github/workflows/release.yml` builds and publishes:

- Android AAR
- iOS xcframework
- macOS universal CLI
- Linux x64 CLI
- Windows x64 CLI

GitHub Release assets use platform-prefixed filenames because release assets
share one flat namespace, for example `linux-x64-ffmpeg.tar.gz`. Files under
`dist/` keep the generic artifact names listed above.

Linux x64 is built on Ubuntu 22.04 and gated by `DESKTOP_LINUX_MAX_GLIBC`
from `versions.env`. The old `ffmpeg-static` dependency used John Van Sickle
static Linux builds with an older glibc baseline; this repo keeps pinned
sources and avoids a fully static glibc build, but must not drift back to
Ubuntu 24.04-only binaries.

Linux arm64 and Windows arm64 are script targets, but are not release-gated yet.

Desktop binary locations:

| Target | Build input | Build output | Release asset | Release-test location |
| --- | --- | --- | --- | --- |
| Linux x64 | pinned source | `../ffmpeg-packaging-test/dist/desktop/linux-x64/ffmpeg.tar.gz` | `linux-x64-ffmpeg.tar.gz` | `../ffmpeg-packaging-test/release-assets/<tag>/linux-x64/` |
| Linux arm64 | pinned source | `../ffmpeg-packaging-test/dist/desktop/linux-arm64/ffmpeg.tar.gz` | `linux-arm64-ffmpeg.tar.gz` | `../ffmpeg-packaging-test/release-assets/<tag>/linux-arm64/` |
| macOS universal | pinned source | `../ffmpeg-packaging-test/dist/desktop/darwin-universal/ffmpeg.tar.gz` | `darwin-universal-ffmpeg.tar.gz` | `../ffmpeg-packaging-test/release-assets/<tag>/darwin-universal/` |
| Windows x64 | pinned source | `../ffmpeg-packaging-test/dist/desktop/windows-x64/ffmpeg.zip` | `windows-x64-ffmpeg.zip` | `../ffmpeg-packaging-test/release-assets/<tag>/windows-x64/` |
| Windows arm64 | pinned source | `../ffmpeg-packaging-test/dist/desktop/windows-arm64/ffmpeg.zip` | `windows-arm64-ffmpeg.zip` | `../ffmpeg-packaging-test/release-assets/<tag>/windows-arm64/` |

Desktop release assets are never used as build inputs. To validate already
published desktop assets, download them into the sibling test directory:

```sh
scripts/download-release-desktop-assets.sh <tag> linux-x64 darwin-universal windows-x64
```

Then run the desktop verifier against the extracted binaries. The
`desktop-release-assets.yml` workflow does this on native runners where
possible.

## Validation

Fast source checks:

```sh
bash -n scripts/*.sh tests/ffi_harness/run-mobile-harness.sh
python3 -m py_compile tests/desktop_cli/verify_media.py
scripts/validate-fftools-state-audit.sh <ffmpeg-source-tree>
```

Desktop CLI checks:

```sh
scripts/verify-desktop-cli.sh ../ffmpeg-packaging-test/dist/desktop/linux-x64
```

The desktop verifier covers build flags, MP4 encode, `ffprobe` JSON, zscale,
tonemap, and Photos-shaped encrypted single-file HLS generation.

Runtime harnesses:

```sh
tests/ffi_harness/run-mobile-harness.sh --android-device <adb-id>
tests/ffi_harness/run-mobile-harness.sh --ios-simulator <simulator-udid>
```

Physical iOS device coverage still needs a signed app or Flutter harness before
release promotion.
