#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  tests/ffi_harness/run-mobile-harness.sh [--android-device <id>] [--ios-simulator <udid>]

Builds and runs the native FFmpeg FFI runtime harness against already-built
mobile artifacts. Android currently requires android-arm64. iOS uses the
ios-sim-arm64 build and a bootable simulator.
USAGE
}

android_device=""
ios_simulator=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --android-device)
      android_device="${2:-}"
      shift 2
      ;;
    --ios-simulator)
      ios_simulator="${2:-}"
      shift 2
      ;;
    --ios-device)
      die "physical iOS device harness is not implemented; use --ios-simulator for simulator coverage"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$android_device" ] || [ -n "$ios_simulator" ] || {
  usage
  exit 2
}

harness_src="$REPO_ROOT/tests/ffi_harness/ffmpeg_ffi_harness.c"
require_file "$harness_src"
ensure_common_dirs

build_android_harness() {
  require_cmd adb
  android_target_vars android-arm64

  local ndk_root
  ndk_root="$(android_ndk_root)"
  [ -d "$ndk_root" ] || die "set ANDROID_NDK_ROOT or install NDK $ANDROID_NDK_VERSION under ANDROID_HOME"

  local host_tag
  case "$(uname -s)" in
    Darwin) host_tag=darwin-x86_64 ;;
    Linux) host_tag=linux-x86_64 ;;
    *) die "unsupported Android build host: $(uname -s)" ;;
  esac

  local clang="$ndk_root/toolchains/llvm/prebuilt/$host_tag/bin/$ANDROID_TRIPLE$ANDROID_API-clang"
  require_executable "$clang"

  local lib_dir="$BUILD_ROOT/android-arm64/package/jni/arm64-v8a"
  local out_dir="$WORK_ROOT/ffi-harness/android-arm64"
  require_file "$lib_dir/libffmpeg_ffi.so"
  reset_dir "$out_dir"

  "$clang" \
    -I"$REPO_ROOT/include" \
    "$harness_src" \
    -L"$lib_dir" \
    -lffmpeg_ffi \
    -Wl,-rpath,'$ORIGIN' \
    -o "$out_dir/ffmpeg_ffi_harness"

  cp "$lib_dir"/*.so "$out_dir/"
}

run_android_harness() {
  local out_dir="$WORK_ROOT/ffi-harness/android-arm64"
  local remote_dir="/data/local/tmp/ffmpeg-ffi-harness"

  build_android_harness
  adb -s "$android_device" shell "rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
  adb -s "$android_device" push "$out_dir/." "$remote_dir/" >/dev/null
  adb -s "$android_device" shell "chmod 755 '$remote_dir/ffmpeg_ffi_harness'"
  adb -s "$android_device" shell "cd '$remote_dir' && LD_LIBRARY_PATH='$remote_dir' ./ffmpeg_ffi_harness"
}

build_ios_harness() {
  ios_target_vars ios-sim-arm64

  local lib_dir="$BUILD_ROOT/ios-sim-arm64/package"
  local out_dir="$WORK_ROOT/ffi-harness/ios-sim-arm64"
  require_file "$lib_dir/ffmpeg_ffi.dylib"
  reset_dir "$out_dir"

  "$IOS_CLANG" \
    -arch "$IOS_ARCH" \
    -target "$IOS_TARGET" \
    "$IOS_MIN_FLAG" \
    -isysroot "$IOS_SDK_PATH" \
    -I"$REPO_ROOT/include" \
    "$harness_src" \
    "$lib_dir/ffmpeg_ffi.dylib" \
    -Wl,-rpath,@executable_path \
    -o "$out_dir/ffmpeg_ffi_harness"
  cp "$lib_dir/ffmpeg_ffi.dylib" "$out_dir/"
  codesign -s - "$out_dir/ffmpeg_ffi_harness" >/dev/null 2>&1 || true
}

run_ios_harness() {
  local out_dir="$WORK_ROOT/ffi-harness/ios-sim-arm64"
  local spawn_dir="/tmp/ffmpeg-ffi-harness-ios-sim-${ios_simulator}"

  build_ios_harness
  reset_dir "$spawn_dir"
  cp "$out_dir/ffmpeg_ffi_harness" "$out_dir/ffmpeg_ffi.dylib" "$spawn_dir/"
  chmod 755 "$spawn_dir/ffmpeg_ffi_harness"
  xcrun simctl bootstatus "$ios_simulator" -b >/dev/null
  set +e
  SIMCTL_CHILD_DYLD_LIBRARY_PATH="$spawn_dir" \
    xcrun simctl spawn -a "$IOS_ARCH" "$ios_simulator" \
      "$spawn_dir/ffmpeg_ffi_harness"
  local spawn_status=$?
  set -e
  rm -rf "$spawn_dir"
  return "$spawn_status"
}

if [ -n "$android_device" ]; then
  run_android_harness
fi

if [ -n "$ios_simulator" ]; then
  run_ios_harness
fi
