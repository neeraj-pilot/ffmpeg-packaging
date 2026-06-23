#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/verify-mobile.sh [--target <target>]... [--android-device <id>] [--ios-simulator <udid>]

Runs packaging-level mobile gates. Device runtime harnesses are only run when
device IDs are provided and a production harness exists under tests/ffi_harness.
USAGE
}

android_device=""
ios_simulator=""
targets=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      target_is_mobile "${2:-}" || die "unknown mobile target: ${2:-}"
      targets+=("$2")
      shift 2
      ;;
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

require_cmd rg
ensure_common_dirs

if [ "${#targets[@]}" -eq 0 ]; then
  # shellcheck disable=SC2206
  targets=($MOBILE_TARGETS)
fi

android_aar="$DIST_ROOT/mobile/android/ffmpeg.aar"
ios_xcframework="$DIST_ROOT/mobile/ios/ffmpeg.xcframework"
needs_android=0
needs_ios=0
has_android_arm64=0
has_android_armv7=0
has_ios_device=0
has_ios_sim=0

for target in "${targets[@]}"; do
  manifest="$BUILD_ROOT/$target/package/build-manifest.env"
  require_file "$manifest"
  rg -q "TARGET=$target" "$manifest" || die "$manifest does not match $target"
  case "$target" in
    android-arm64) needs_android=1; has_android_arm64=1 ;;
    android-armv7) needs_android=1; has_android_armv7=1 ;;
    ios-device-arm64) needs_ios=1; has_ios_device=1 ;;
    ios-sim-arm64) needs_ios=1; has_ios_sim=1 ;;
  esac
done

if [ "$needs_android" -eq 1 ]; then
  if [ "$has_android_arm64" -eq 1 ] && [ "$has_android_armv7" -eq 1 ]; then
    "$REPO_ROOT/scripts/package-android-aar.sh" "$android_aar"
  else
    log "skip Android AAR packaging; android-arm64 and android-armv7 are both required"
  fi
fi
if [ "$needs_ios" -eq 1 ]; then
  if [ "$has_ios_device" -eq 1 ] && [ "$has_ios_sim" -eq 1 ]; then
    "$REPO_ROOT/scripts/package-ios-xcframework.sh" "$ios_xcframework"
  else
    log "skip iOS xcframework packaging; ios-device-arm64 and ios-sim-arm64 are both required"
  fi
fi

if [ -n "$android_device" ] || [ -n "$ios_simulator" ]; then
  harness="$REPO_ROOT/tests/ffi_harness/run-mobile-harness.sh"
  require_file "$harness"
  [ -x "$harness" ] || die "$harness must be executable"
  args=()
  [ -z "$android_device" ] || args+=(--android-device "$android_device")
  [ -z "$ios_simulator" ] || args+=(--ios-simulator "$ios_simulator")
  "$harness" "${args[@]}"
fi

log "mobile verification complete"
