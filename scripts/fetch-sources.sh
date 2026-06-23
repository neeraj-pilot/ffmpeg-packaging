#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/fetch-sources.sh

Downloads or refreshes pinned FFmpeg, x264, and zimg sources into SOURCES_ROOT.
The FFmpeg tarball checksum is mandatory and verified from versions.env.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || { usage; exit 2; }

require_cmd curl
require_cmd git
require_cmd tar
ensure_common_dirs

ffmpeg_archive="$DOWNLOADS_ROOT/ffmpeg-$FFMPEG_VERSION.tar.xz"
ffmpeg_dir="$(ffmpeg_source_dir)"

if [ ! -f "$ffmpeg_archive" ]; then
  log "download $FFMPEG_URL"
  curl -fL "$FFMPEG_URL" -o "$ffmpeg_archive"
fi
verify_sha256 "$ffmpeg_archive" "$FFMPEG_SHA256"

if [ ! -d "$ffmpeg_dir" ]; then
  log "extract FFmpeg $FFMPEG_VERSION"
  reset_dir "$ffmpeg_dir"
  tar -xf "$ffmpeg_archive" -C "$SOURCES_ROOT"
fi
require_file "$ffmpeg_dir/configure"

fetch_git_source() {
  local name="$1"
  local url="$2"
  local rev="$3"
  local output_dir="$4"
  local cache_dir="$WORK_ROOT/git-cache/$name.git"

  if [ -d "$output_dir" ]; then
    return
  fi

  mkdir -p "$(dirname "$cache_dir")"
  if [ ! -d "$cache_dir" ]; then
    log "clone $name"
    git clone --bare "$url" "$cache_dir"
  else
    log "refresh $name"
    git -C "$cache_dir" fetch --tags origin
  fi

  reset_dir "$output_dir"
  git -C "$cache_dir" archive "$rev" | tar -x -C "$output_dir"
}

fetch_git_source x264 "$X264_GIT_URL" "$X264_REVISION" "$(x264_source_dir)"
fetch_git_source zimg "$ZIMG_GIT_URL" "$ZIMG_REVISION" "$(zimg_source_dir)"

write_manifest "$SOURCES_ROOT/source-manifest.env" \
  "FFMPEG_URL=$FFMPEG_URL" \
  "X264_GIT_URL=$X264_GIT_URL" \
  "ZIMG_GIT_URL=$ZIMG_GIT_URL"

log "sources ready under $SOURCES_ROOT"
