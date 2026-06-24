#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="${REPO_ROOT:-$(cd "$script_dir/.." && pwd)}"
repo_parent="$(cd "$REPO_ROOT/.." && pwd)"
export FFMPEG_PACKAGING_TEST_ROOT="${FFMPEG_PACKAGING_TEST_ROOT:-$repo_parent/ffmpeg-packaging-test}"

set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"
set +a

export SOURCES_ROOT="${SOURCES_ROOT:-$FFMPEG_PACKAGING_TEST_ROOT/sources}"
export DOWNLOADS_ROOT="${DOWNLOADS_ROOT:-$FFMPEG_PACKAGING_TEST_ROOT/downloads}"
export BUILD_ROOT="${BUILD_ROOT:-$FFMPEG_PACKAGING_TEST_ROOT/build}"
export DIST_ROOT="${DIST_ROOT:-$FFMPEG_PACKAGING_TEST_ROOT/dist}"
export WORK_ROOT="${WORK_ROOT:-$FFMPEG_PACKAGING_TEST_ROOT/work}"
export JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

require_dir() {
  [ -d "$1" ] || die "missing directory: $1"
}

require_executable() {
  [ -x "$1" ] || die "missing executable: $1"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  if command -v certutil >/dev/null 2>&1; then
    certutil -hashfile "$1" SHA256 | awk 'NR == 2 {print tolower($0)}'
    return
  fi
  die "missing sha256 tool"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  [ -n "$expected" ] || die "missing checksum for $file"
  actual="$(sha256_file "$file")"
  [ "$actual" = "$expected" ] ||
    die "checksum mismatch for $file: expected $expected got $actual"
}

reset_dir() {
  local path="$1"
  rm -rf "$path"
  mkdir -p "$path"
}

copy_clean_tree() {
  local source_dir="$1"
  local output_dir="$2"
  reset_dir "$output_dir"
  (cd "$source_dir" && tar -cf - .) | tar -xf - -C "$output_dir"
}

normalize_zimg_pkg_config() {
  local pc_file="$1"
  local private_libs="$2"

  sed -i.bak "s/^Libs\\.private:.*/Libs.private: $private_libs/" "$pc_file"
  rm -f "$pc_file.bak"
}

ensure_common_dirs() {
  mkdir -p "$SOURCES_ROOT" "$DOWNLOADS_ROOT" "$BUILD_ROOT" "$DIST_ROOT" "$WORK_ROOT"
}

ffmpeg_source_dir() {
  printf '%s/ffmpeg-%s\n' "$SOURCES_ROOT" "$FFMPEG_VERSION"
}

x264_source_dir() {
  printf '%s/x264-%s\n' "$SOURCES_ROOT" "$X264_REVISION"
}

zimg_source_dir() {
  printf '%s/zimg-%s\n' "$SOURCES_ROOT" "$ZIMG_REVISION"
}

boundary_patch() {
  printf '%s/patches/ffmpeg-8.1/ffmpeg-ffi-boundary.patch\n' "$REPO_ROOT"
}

target_is_mobile() {
  case " $MOBILE_TARGETS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

target_is_desktop() {
  case " $DESKTOP_TARGETS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

android_target_vars() {
  case "$1" in
    android-arm64)
      ABI=arm64-v8a
      ANDROID_ARCH=aarch64
      ANDROID_CPU=armv8-a
      ANDROID_TRIPLE=aarch64-linux-android
      FFMPEG_ARCH=aarch64
      ;;
    android-armv7)
      ABI=armeabi-v7a
      ANDROID_ARCH=armv7a
      ANDROID_CPU=armv7-a
      ANDROID_TRIPLE=armv7a-linux-androideabi
      FFMPEG_ARCH=arm
      ;;
    *)
      die "unknown Android target: $1"
      ;;
  esac
  export ABI ANDROID_ARCH ANDROID_CPU ANDROID_TRIPLE FFMPEG_ARCH
}

android_ndk_root() {
  if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
    printf '%s\n' "$ANDROID_NDK_ROOT"
    return
  fi
  if [ -n "${ANDROID_HOME:-}" ]; then
    if [ -d "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION" ]; then
      printf '%s\n' "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION"
      return
    fi
  fi
  if [ -d "$HOME/Library/Android/sdk/ndk/$ANDROID_NDK_VERSION" ]; then
    printf '%s\n' "$HOME/Library/Android/sdk/ndk/$ANDROID_NDK_VERSION"
    return
  fi
  printf '\n'
}

ios_target_vars() {
  case "$1" in
    ios-device-arm64)
      IOS_SDK_NAME=iphoneos
      IOS_ARCH=arm64
      IOS_TARGET=arm64-apple-ios"$IOS_MIN_VERSION"
      IOS_MIN_FLAG=-miphoneos-version-min="$IOS_MIN_VERSION"
      ;;
    ios-sim-arm64)
      IOS_SDK_NAME=iphonesimulator
      IOS_ARCH=arm64
      IOS_TARGET=arm64-apple-ios"$IOS_MIN_VERSION"-simulator
      IOS_MIN_FLAG=-mios-simulator-version-min="$IOS_MIN_VERSION"
      ;;
    *)
      die "unknown iOS target: $1"
      ;;
  esac
  require_cmd xcrun
  IOS_SDK_PATH="$(xcrun --sdk "$IOS_SDK_NAME" --show-sdk-path)"
  IOS_CLANG="$(xcrun --sdk "$IOS_SDK_NAME" -find clang)"
  IOS_CLANGXX="$(xcrun --sdk "$IOS_SDK_NAME" -find clang++)"
  IOS_AR="$(xcrun --sdk "$IOS_SDK_NAME" -find ar)"
  IOS_RANLIB="$(xcrun --sdk "$IOS_SDK_NAME" -find ranlib)"
  IOS_STRIP="$(xcrun --sdk "$IOS_SDK_NAME" -find strip)"
  export IOS_SDK_NAME IOS_ARCH IOS_TARGET IOS_MIN_FLAG IOS_SDK_PATH
  export IOS_CLANG IOS_CLANGXX IOS_AR IOS_RANLIB IOS_STRIP
}

desktop_target_vars() {
  case "$1" in
    desktop-darwin-arm64)
      DESKTOP_OS=darwin
      DESKTOP_ARCH=arm64
      FFMPEG_ARCH=arm64
      ;;
    desktop-darwin-x64)
      DESKTOP_OS=darwin
      DESKTOP_ARCH=x86_64
      FFMPEG_ARCH=x86_64
      ;;
    desktop-linux-x64)
      DESKTOP_OS=linux
      DESKTOP_ARCH=x86_64
      FFMPEG_ARCH=x86_64
      ;;
    desktop-linux-arm64)
      DESKTOP_OS=linux
      DESKTOP_ARCH=aarch64
      FFMPEG_ARCH=aarch64
      ;;
    desktop-windows-x64)
      DESKTOP_OS=mingw32
      DESKTOP_ARCH=x86_64
      FFMPEG_ARCH=x86_64
      ;;
    desktop-windows-arm64)
      DESKTOP_OS=mingw32
      DESKTOP_ARCH=aarch64
      FFMPEG_ARCH=aarch64
      ;;
    *)
      die "unknown desktop target: $1"
      ;;
  esac
  export DESKTOP_OS DESKTOP_ARCH FFMPEG_ARCH
}

find_readelf() {
  if [ -n "${READELF:-}" ]; then
    printf '%s\n' "$READELF"
    return
  fi
  local ndk_root
  ndk_root="$(android_ndk_root)"
  if [ -n "$ndk_root" ]; then
    find "$ndk_root/toolchains/llvm/prebuilt" \
      -path '*/bin/llvm-readelf' \( -type f -o -type l \) -print -quit 2>/dev/null || true
    return
  fi
  if command -v llvm-readelf >/dev/null 2>&1; then
    command -v llvm-readelf
    return
  fi
  if command -v readelf >/dev/null 2>&1; then
    command -v readelf
    return
  fi
  if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
    find "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt" \
      -path '*/bin/llvm-readelf' \( -type f -o -type l \) -print -quit 2>/dev/null || true
    return
  fi
  if [ -n "${ANDROID_HOME:-}" ]; then
    find "$ANDROID_HOME/ndk" \
      -path '*/toolchains/llvm/prebuilt/*/bin/llvm-readelf' \( -type f -o -type l \) -print -quit 2>/dev/null || true
    return
  fi
  find "$HOME/Library/Android/sdk/ndk" \
    -path '*/toolchains/llvm/prebuilt/*/bin/llvm-readelf' \( -type f -o -type l \) -print -quit 2>/dev/null || true
}

assert_android_load_alignment() {
  local readelf_bin="$1"
  local lib="$2"
  local report="$WORK_ROOT/readelf-$(basename "$lib").txt"
  "$readelf_bin" -lW "$lib" > "$report"
  python3 - "$lib" "$report" <<'PY'
import sys

lib = sys.argv[1]
report = sys.argv[2]
bad = []
with open(report, encoding="utf-8") as handle:
    for line in handle:
        if not line.lstrip().startswith("LOAD"):
            continue
        fields = line.split()
        if not fields:
            continue
        try:
            align = int(fields[-1], 16)
        except ValueError:
            bad.append(line.rstrip())
            continue
        if align < 0x4000:
            bad.append(line.rstrip())
if bad:
    print(f"{lib}: LOAD alignment below 16 KB", file=sys.stderr)
    for line in bad:
        print(line, file=sys.stderr)
    sys.exit(1)
PY
}

write_manifest() {
  local output="$1"
  shift
  {
    printf 'FFMPEG_TAG=%s\n' "$FFMPEG_TAG"
    printf 'FFMPEG_SHA256=%s\n' "$FFMPEG_SHA256"
    printf 'X264_REVISION=%s\n' "$X264_REVISION"
    printf 'ZIMG_REVISION=%s\n' "$ZIMG_REVISION"
    printf 'BUILD_TIME_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for item in "$@"; do
      printf '%s\n' "$item"
    done
  } > "$output"
}
