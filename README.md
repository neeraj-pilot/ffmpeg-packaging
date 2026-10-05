# FFmpeg Packaging

Builds pinned FFmpeg artifacts for mobile and desktop consumers without
vendoring downloaded sources or generated outputs.

## What This Produces

| Platform | Artifact |
| --- | --- |
| Android | `dist/mobile/android/ffmpeg-runtime.aar` |
| iOS | `dist/mobile/ios/FFmpegRuntime.xcframework.zip` (Swift Package Manager binary target) |
| macOS | `dist/desktop/darwin-universal/ffmpeg.tar.gz` |
| Linux x64 / ARM64 | `dist/desktop/linux-{x64,arm64}/ffmpeg.tar.gz` |
| Windows x64 / ARM64 | `dist/desktop/windows-{x64,arm64}/ffmpeg.zip` |

The embedded mobile library is FFmpegRuntime on iOS and libffmpeg_runtime.so
on Android. Desktop artifacts contain the ffmpeg and ffprobe command-line tools.

## Repository Layout

- `versions.env`: source and toolchain pins
- `scripts/`: fetch, build, package, and verify entrypoints
- `include/ffmpeg_runtime.h`: public mobile C ABI
- `src/`: mobile wrapper support code that does not patch FFmpeg
- `patches/`: reviewable FFmpeg source patches
- `docs/mobile-fftools-patch.md`: why the mobile `fftools` patch exists
- `tests/desktop_cli/`: desktop CLI media verification
- `tests/runtime/`: native mobile runtime harness

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
scripts/build-desktop-cli.sh desktop-linux-arm64
scripts/build-desktop-cli.sh desktop-windows-x64
scripts/build-desktop-cli.sh desktop-windows-arm64
```

Use `--help` on individual scripts for target-specific options.
Desktop builds also require Meson and Ninja to build the pinned dav1d software
AV1 decoder. macOS CLI artifacts target macOS 13.3, matching Photos.

## CI And Releases

`.github/workflows/release.yml` builds and publishes:

- Android AAR
- iOS xcframework
- macOS universal CLI
- Linux x64 and ARM64 CLI
- Windows x64 and ARM64 CLI

GitHub Release assets use platform-prefixed filenames because release assets
share one flat namespace, for example `linux-x64-ffmpeg.tar.gz`. Files under
`dist/` keep the generic artifact names listed above.

Linux x64 and ARM64 are built on Ubuntu 22.04 and gated by `DESKTOP_LINUX_MAX_GLIBC`
from `versions.env`; release binaries must not drift to an Ubuntu 24.04-only
glibc baseline.

Windows ARM64 builds natively with MSYS2 CLANGARM64. Every desktop architecture
must pass media runtime checks before the release is published.

Desktop binary locations:

| Target | Build output | Release asset | Release-test location |
| --- | --- | --- | --- |
| Linux x64 | `../ffmpeg-packaging-test/dist/desktop/linux-x64/ffmpeg.tar.gz` | `linux-x64-ffmpeg.tar.gz` | `../ffmpeg-packaging-test/release-assets/<tag>/linux-x64/` |
| Linux ARM64 | `../ffmpeg-packaging-test/dist/desktop/linux-arm64/ffmpeg.tar.gz` | `linux-arm64-ffmpeg.tar.gz` | `../ffmpeg-packaging-test/release-assets/<tag>/linux-arm64/` |
| macOS universal | `../ffmpeg-packaging-test/dist/desktop/darwin-universal/ffmpeg.tar.gz` | `darwin-universal-ffmpeg.tar.gz` | `../ffmpeg-packaging-test/release-assets/<tag>/darwin-universal/` |
| Windows x64 | `../ffmpeg-packaging-test/dist/desktop/windows-x64/ffmpeg.zip` | `windows-x64-ffmpeg.zip` | `../ffmpeg-packaging-test/release-assets/<tag>/windows-x64/` |
| Windows ARM64 | `../ffmpeg-packaging-test/dist/desktop/windows-arm64/ffmpeg.zip` | `windows-arm64-ffmpeg.zip` | `../ffmpeg-packaging-test/release-assets/<tag>/windows-arm64/` |

Desktop release assets are never used as build inputs. To validate already
published desktop assets, download them into the sibling test directory:

```sh
scripts/download-release-desktop-assets.sh <tag>
```

Then run the desktop verifier against the extracted binaries. The
`desktop-release-assets.yml` workflow covers Linux and Windows on x64 and ARM64,
and macOS universal on Apple Silicon and Intel runners.

## Validation

Fast source checks:

```sh
bash -n scripts/*.sh tests/runtime/run-mobile-harness.sh
python3 - <<'PY'
from pathlib import Path
path = Path("tests/desktop_cli/verify_media.py")
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
scripts/validate-fftools-state-audit.sh <ffmpeg-source-tree>
```

Desktop CLI check example:

```sh
scripts/verify-desktop-cli.sh ../ffmpeg-packaging-test/dist/desktop/linux-x64
```

The desktop verifier covers build flags, software AV1 decode, MP4 encode, `ffprobe` JSON, zscale,
tonemap, and Photos-shaped encrypted single-file HLS generation.

The two-frame AV1 fixture was generated from FFmpeg's test pattern, with no
external media input:

```sh
ffmpeg -f lavfi -i testsrc2=size=64x64:rate=1 -frames:v 2 \
  -c:v libsvtav1 -preset 12 -crf 40 tests/desktop_cli/fixtures/av1.ivf
```

Runtime harnesses:

```sh
tests/runtime/run-mobile-harness.sh --android-device <adb-id>
tests/runtime/run-mobile-harness.sh --ios-simulator <simulator-udid>
```

Physical iOS device coverage still needs a signed app or Flutter harness before
mobile release promotion.
