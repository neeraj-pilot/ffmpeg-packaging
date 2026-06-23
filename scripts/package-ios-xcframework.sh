#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/package-ios-xcframework.sh [output-xcframework]

Packages iOS build outputs into DIST_ROOT/mobile/ios/ffmpeg.xcframework by
default.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -le 1 ] || { usage; exit 2; }

require_cmd xcodebuild
require_cmd nm
require_cmd rg
ensure_common_dirs

output="${1:-$DIST_ROOT/mobile/ios/ffmpeg.xcframework}"
device_lib="$BUILD_ROOT/ios-device-arm64/package/ffmpeg_ffi.dylib"
sim_lib="$BUILD_ROOT/ios-sim-arm64/package/ffmpeg_ffi.dylib"
headers="$REPO_ROOT/include"

require_file "$device_lib"
require_file "$sim_lib"
require_file "$headers/ffmpeg_ffi.h"

mkdir -p "$(dirname "$output")"
rm -rf "$output" "$output.tar.gz" "$output.tar.gz.sha256" "$output.manifest.env"
xcodebuild -create-xcframework \
  -library "$device_lib" -headers "$headers" \
  -library "$sim_lib" -headers "$headers" \
  -output "$output"

for lib in "$device_lib" "$sim_lib"; do
  symbols="$WORK_ROOT/$(basename "$(dirname "$(dirname "$lib")")")-symbols.txt"
  nm -gU "$lib" > "$symbols"
  for symbol in _ffmpeg_session_new _ffmpeg_session_free _ffmpeg_execute _ffmpeg_cancel _ffmpeg_probe_media_json _ffmpeg_free_string; do
    rg -q "$symbol" "$symbols" || die "$lib missing symbol $symbol"
  done
done

tar -C "$(dirname "$output")" -czf "$output.tar.gz" "$(basename "$output")"
sha256_file "$output.tar.gz" > "$output.tar.gz.sha256"
write_manifest "$output.manifest.env" "ARTIFACT=$output" "TARGETS=ios-device-arm64 ios-sim-arm64"

log "packaged $output"
