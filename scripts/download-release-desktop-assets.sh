#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/download-release-desktop-assets.sh <tag> [target...]

Targets:
  linux-x64
  linux-arm64
  darwin-universal
  windows-x64
  windows-arm64

Downloads GitHub Release desktop assets into:
  FFMPEG_PACKAGING_TEST_ROOT/release-assets/<tag>/<target>/

This is validation-only. Downloaded release binaries are never build inputs.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -ge 1 ] || { usage; exit 2; }

tag="$1"
shift

release_repo="${FFMPEG_RELEASE_REPO:-${GITHUB_REPOSITORY:-neeraj-pilot/ffmpeg-packaging}}"
release_root="$FFMPEG_PACKAGING_TEST_ROOT/release-assets/$tag"

require_cmd curl
require_cmd tar
require_cmd unzip
ensure_common_dirs

if [ "$#" -eq 0 ]; then
  set -- linux-x64 darwin-universal windows-x64
fi

asset_name() {
  case "$1" in
    linux-x64) printf '%s\n' linux-x64-ffmpeg.tar.gz ;;
    linux-arm64) printf '%s\n' linux-arm64-ffmpeg.tar.gz ;;
    darwin-universal) printf '%s\n' darwin-universal-ffmpeg.tar.gz ;;
    windows-x64) printf '%s\n' windows-x64-ffmpeg.zip ;;
    windows-arm64) printf '%s\n' windows-arm64-ffmpeg.zip ;;
    *) die "unknown desktop release target: $1" ;;
  esac
}

extract_asset() {
  local target="$1"
  local archive="$2"
  case "$archive" in
    *.tar.gz) tar -xzf "$archive" -C "$release_root/$target" ;;
    *.zip) unzip -q "$archive" -d "$release_root/$target" ;;
    *) die "unsupported archive: $archive" ;;
  esac
}

for target in "$@"; do
  archive_name="$(asset_name "$target")"
  output_dir="$release_root/$target"
  archive="$output_dir/$archive_name"
  checksum="$archive.sha256"
  reset_dir "$output_dir"

  base_url="https://github.com/$release_repo/releases/download/$tag"
  curl -fL "$base_url/$archive_name" -o "$archive"
  curl -fL "$base_url/$archive_name.sha256" -o "$checksum"
  expected="$(awk 'NR == 1 {print $1}' "$checksum" | tr -cd '[:xdigit:]')"
  verify_sha256 "$archive" "$expected"
  extract_asset "$target" "$archive"

  case "$target" in
    windows-*)
      require_file "$output_dir/ffmpeg.exe"
      require_file "$output_dir/ffprobe.exe"
      printf '%s\t%s\t%s\n' "$target" "$output_dir/ffmpeg.exe" "$output_dir/ffprobe.exe"
      ;;
    *)
      require_file "$output_dir/ffmpeg"
      require_file "$output_dir/ffprobe"
      chmod +x "$output_dir/ffmpeg" "$output_dir/ffprobe"
      printf '%s\t%s\t%s\n' "$target" "$output_dir/ffmpeg" "$output_dir/ffprobe"
      ;;
  esac
done
