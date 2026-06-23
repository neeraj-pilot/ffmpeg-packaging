#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/verify-desktop-windows.sh <artifact-dir> <target>

Verifies a cross-built Windows desktop artifact directory. This is an archive
and dependency-shape check only; it does not execute the Windows binaries.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 2 ] || { usage; exit 2; }
artifact_dir="$1"
target="$2"

desktop_target_vars "$target"
[ "$DESKTOP_OS" = "mingw32" ] || die "not a Windows desktop target: $target"

require_dir "$artifact_dir"
require_file "$artifact_dir/ffmpeg.exe"
require_file "$artifact_dir/ffprobe.exe"
require_file "$artifact_dir/ffmpeg.zip"
require_file "$artifact_dir/ffmpeg.zip.sha256"
require_file "$artifact_dir/ffmpeg.zip.manifest.env"
require_cmd unzip
require_cmd rg

case "$DESKTOP_ARCH" in
  x86_64) objdump="${OBJDUMP:-x86_64-w64-mingw32-objdump}" ;;
  aarch64) objdump="${OBJDUMP:-aarch64-w64-mingw32-objdump}" ;;
  *) die "unsupported Windows desktop architecture: $DESKTOP_ARCH" ;;
esac
require_cmd "$objdump"

unzip -t "$artifact_dir/ffmpeg.zip" >/dev/null
unzip -l "$artifact_dir/ffmpeg.zip" > "$WORK_ROOT/windows-archive-list.txt"
rg -q 'ffmpeg\.exe' "$WORK_ROOT/windows-archive-list.txt" ||
  die "Windows archive missing ffmpeg.exe"
rg -q 'ffprobe\.exe' "$WORK_ROOT/windows-archive-list.txt" ||
  die "Windows archive missing ffprobe.exe"

for exe in ffmpeg.exe ffprobe.exe; do
  report="$WORK_ROOT/windows-${exe%.exe}-objdump.txt"
  "$objdump" -p "$artifact_dir/$exe" > "$report"
  if rg -qi 'DLL Name: (libstdc\+\+-6|libgcc_s|libwinpthread|libx264|libzimg|zlib)' "$report"; then
    die "$exe depends on an unpackaged runtime or pinned media library DLL"
  fi
done

log "Windows desktop archive verification complete for $artifact_dir"
