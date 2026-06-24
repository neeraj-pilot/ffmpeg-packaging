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
require_cmd install_name_tool
require_cmd nm
require_cmd otool
require_cmd rg
ensure_common_dirs

output="${1:-$DIST_ROOT/mobile/ios/ffmpeg.xcframework}"
device_lib="$BUILD_ROOT/ios-device-arm64/package/ffmpeg_ffi.dylib"
sim_lib="$BUILD_ROOT/ios-sim-arm64/package/ffmpeg_ffi.dylib"
headers="$REPO_ROOT/include"
stage="$WORK_ROOT/ios-xcframework"

require_file "$device_lib"
require_file "$sim_lib"
require_file "$headers/ffmpeg_ffi.h"

mkdir -p "$(dirname "$output")"
rm -rf "$output" "$output.tar.gz" "$output.tar.gz.sha256" "$output.manifest.env"
reset_dir "$stage"

create_framework() {
  local source_lib="$1"
  local platform="$2"
  local framework="$stage/$platform/ffmpeg_ffi.framework"

  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$source_lib" "$framework/ffmpeg_ffi"
  chmod 755 "$framework/ffmpeg_ffi"
  install_name_tool -id "@rpath/ffmpeg_ffi.framework/ffmpeg_ffi" "$framework/ffmpeg_ffi"
  cp "$headers/ffmpeg_ffi.h" "$framework/Headers/ffmpeg_ffi.h"
  cat > "$framework/Modules/module.modulemap" <<'EOF'
framework module ffmpeg_ffi {
  umbrella header "ffmpeg_ffi.h"
  export *
}
EOF
  cat > "$framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ffmpeg_ffi</string>
  <key>CFBundleIdentifier</key>
  <string>org.ffmpeg.ffi</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ffmpeg_ffi</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>$FFMPEG_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$FFMPEG_VERSION</string>
  <key>MinimumOSVersion</key>
  <string>$IOS_MIN_VERSION</string>
</dict>
</plist>
EOF
}

create_framework "$device_lib" ios-device-arm64
create_framework "$sim_lib" ios-sim-arm64

xcodebuild -create-xcframework \
  -framework "$stage/ios-device-arm64/ffmpeg_ffi.framework" \
  -framework "$stage/ios-sim-arm64/ffmpeg_ffi.framework" \
  -output "$output"

while IFS= read -r -d '' framework; do
  lib="$framework/ffmpeg_ffi"
  require_file "$framework/Headers/ffmpeg_ffi.h"
  require_file "$framework/Modules/module.modulemap"
  require_file "$framework/Info.plist"
  symbols="$WORK_ROOT/$(basename "$(dirname "$framework")")-symbols.txt"
  install_name="$WORK_ROOT/$(basename "$(dirname "$framework")")-install-name.txt"
  nm -gU "$lib" > "$symbols"
  for symbol in _ffmpeg_session_new _ffmpeg_session_free _ffmpeg_execute _ffmpeg_cancel _ffmpeg_probe_media_json _ffmpeg_free_string; do
    rg -q "$symbol" "$symbols" || die "$lib missing symbol $symbol"
  done
  otool -D "$lib" > "$install_name"
  rg -q '@rpath/ffmpeg_ffi\.framework/ffmpeg_ffi' "$install_name" ||
    die "$lib has wrong install name"
done < <(find "$output" -name 'ffmpeg_ffi.framework' -type d -print0)

tar -C "$(dirname "$output")" -czf "$output.tar.gz" "$(basename "$output")"
sha256_file "$output.tar.gz" > "$output.tar.gz.sha256"
write_manifest "$output.manifest.env" "ARTIFACT=$output" "TARGETS=ios-device-arm64 ios-sim-arm64"

log "packaged $output"
