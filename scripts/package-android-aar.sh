#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/package-android-aar.sh [output-aar]

Packages Android build outputs into a production AAR at
DIST_ROOT/mobile/android/ffmpeg.aar by default.
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

output="${1:-$DIST_ROOT/mobile/android/ffmpeg.aar}"
stage="$WORK_ROOT/android-aar"
readelf_bin="$(find_readelf)"
require_executable "$readelf_bin"

reset_dir "$stage"
mkdir -p "$stage/jni/arm64-v8a" "$stage/jni/armeabi-v7a" "$(dirname "$output")"
cat > "$stage/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.ffmpeg.ffi" />
EOF

copy_abi() {
  local target="$1"
  local abi="$2"
  local source="$BUILD_ROOT/$target/package/jni/$abi"
  require_dir "$source"
  cp "$source"/*.so "$stage/jni/$abi/"
}

copy_abi android-arm64 arm64-v8a
copy_abi android-armv7 armeabi-v7a

if find "$stage/jni" -name 'libc++_shared.so' -print -quit | rg -q .; then
  die "Android FFmpeg AAR must not bundle libc++_shared.so"
fi

for abi in arm64-v8a armeabi-v7a; do
  wrapper="$stage/jni/$abi/libffmpeg_ffi.so"
  require_file "$wrapper"
  "$readelf_bin" -Ws "$wrapper" > "$WORK_ROOT/$abi-libffmpeg-ffi.symbols"
  "$readelf_bin" -d "$wrapper" > "$WORK_ROOT/$abi-libffmpeg-ffi.dynamic"
  for symbol in ffmpeg_session_new ffmpeg_session_free ffmpeg_execute ffmpeg_cancel ffmpeg_probe_media_json ffmpeg_free_string; do
    rg -q "[[:space:]]$symbol([[:space:]]|$)" "$WORK_ROOT/$abi-libffmpeg-ffi.symbols" ||
      die "$wrapper missing exported symbol $symbol"
  done
  for needed in libavdevice.so libavfilter.so libavformat.so libavcodec.so libswresample.so libswscale.so libavutil.so; do
    rg -q "Shared library: \\[$needed\\]" "$WORK_ROOT/$abi-libffmpeg-ffi.dynamic" ||
      die "$wrapper missing dependency $needed"
  done
  for lib in "$stage/jni/$abi"/*.so; do
    dynamic="$WORK_ROOT/$abi-$(basename "$lib").dynamic"
    "$readelf_bin" -d "$lib" > "$dynamic"
    if rg -q 'Shared library: \[libc\+\+_shared\.so\]' "$dynamic"; then
      die "$lib must not depend on libc++_shared.so"
    fi
    assert_android_load_alignment "$readelf_bin" "$lib"
  done
done

rm -f "$output"
(
  cd "$stage"
  zip -Xqr "$output" AndroidManifest.xml jni
)
sha256_file "$output" > "$output.sha256"
write_manifest "$output.manifest.env" "ARTIFACT=$output" "TARGETS=android-arm64 android-armv7"

log "packaged $output"
