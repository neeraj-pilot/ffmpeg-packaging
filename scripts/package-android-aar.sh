#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/package-android-aar.sh [output-aar]

Packages Android build outputs into a production AAR at
DIST_ROOT/mobile/android/ffmpeg-runtime.aar by default.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -le 1 ] || { usage; exit 2; }

require_cmd zip
require_cmd rg
ensure_common_dirs

output="${1:-$DIST_ROOT/mobile/android/ffmpeg-runtime.aar}"
stage="$WORK_ROOT/android-aar"
readelf_bin="$(find_readelf)"
require_executable "$readelf_bin"

reset_dir "$stage"
mkdir -p "$stage/jni/arm64-v8a" "$stage/jni/armeabi-v7a" "$(dirname "$output")"
cat > "$stage/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="io.ente.ffmpeg.runtime" />
EOF

copy_abi() {
  local target="$1"
  local abi="$2"
  local source="$BUILD_ROOT/$target/package/jni/$abi"
  require_mobile_build "$target"
  require_file "$source/libffmpeg_runtime.so"
  cp "$source/libffmpeg_runtime.so" "$stage/jni/$abi/"
}

copy_abi android-arm64 arm64-v8a
copy_abi android-armv7 armeabi-v7a

for abi in arm64-v8a armeabi-v7a; do
  wrapper="$stage/jni/$abi/libffmpeg_runtime.so"
  require_file "$wrapper"
  "$readelf_bin" -Ws "$wrapper" > "$WORK_ROOT/$abi-libffmpeg-runtime.symbols"
  "$readelf_bin" -d "$wrapper" > "$WORK_ROOT/$abi-libffmpeg-runtime.dynamic"
  for symbol in ffmpeg_session_new ffmpeg_session_free ffmpeg_session_output ffmpeg_execute ffmpeg_cancel ffmpeg_probe_media_json ffmpeg_free_string; do
    rg -q "[[:space:]]$symbol([[:space:]]|$)" "$WORK_ROOT/$abi-libffmpeg-runtime.symbols" ||
      die "$wrapper missing exported symbol $symbol"
  done
  if rg -q 'Shared library: \[lib(av|sw|x264|zimg|c\+\+_shared)' "$WORK_ROOT/$abi-libffmpeg-runtime.dynamic"; then
    die "$wrapper must statically contain its media libraries and C++ runtime"
  fi
  assert_android_load_alignment "$readelf_bin" "$wrapper"
done

rm -f "$output"
(
  cd "$stage"
  zip -Xqr "$output" AndroidManifest.xml jni
)
sha256_file "$output" > "$output.sha256"
write_manifest "$output.manifest.env" "ARTIFACT=$output" "TARGETS=android-arm64 android-armv7"

log "packaged $output"
