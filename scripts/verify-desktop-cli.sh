#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/verify-desktop-cli.sh <artifact-dir>

Verifies an unpacked desktop artifact directory containing ffmpeg and ffprobe.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage; exit 2; }
artifact_dir="$1"

require_dir "$artifact_dir"
require_cmd python3
require_cmd rg
ensure_common_dirs
ffmpeg="$artifact_dir/ffmpeg"
ffprobe="$artifact_dir/ffprobe"
if [ ! -x "$ffmpeg" ] && [ -x "$artifact_dir/ffmpeg.exe" ]; then
  ffmpeg="$artifact_dir/ffmpeg.exe"
fi
if [ ! -x "$ffprobe" ] && [ -x "$artifact_dir/ffprobe.exe" ]; then
  ffprobe="$artifact_dir/ffprobe.exe"
fi
require_executable "$ffmpeg"
require_executable "$ffprobe"

"$ffmpeg" -version > "$WORK_ROOT/desktop-ffmpeg-version.txt"
"$ffmpeg" -buildconf > "$WORK_ROOT/desktop-ffmpeg-buildconf.txt"

rg -q -- '--enable-libx264' "$WORK_ROOT/desktop-ffmpeg-buildconf.txt" ||
  die "desktop ffmpeg missing --enable-libx264"
rg -q -- '--enable-libzimg' "$WORK_ROOT/desktop-ffmpeg-buildconf.txt" ||
  die "desktop ffmpeg missing --enable-libzimg"
rg -q -- '--enable-gpl' "$WORK_ROOT/desktop-ffmpeg-buildconf.txt" ||
  die "desktop ffmpeg missing --enable-gpl"

sample="$WORK_ROOT/desktop-smoke.mp4"
"$ffmpeg" -hide_banner -y \
  -f lavfi -i testsrc2=duration=1:size=160x90:rate=5 \
  -an -c:v libx264 -preset ultrafast "$sample" \
  > "$WORK_ROOT/desktop-mp4-smoke.log" 2>&1
"$ffprobe" -v error -print_format json -show_format -show_streams "$sample" \
  > "$WORK_ROOT/desktop-ffprobe-smoke.json"
python3 - "$WORK_ROOT/desktop-ffprobe-smoke.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if not isinstance(data.get("format"), dict):
    raise SystemExit("missing format object")
if not isinstance(data.get("streams"), list) or not data["streams"]:
    raise SystemExit("missing streams array")
PY

"$ffmpeg" -hide_banner -y \
  -f lavfi -i testsrc2=duration=1:size=160x90:rate=5 \
  -vf zscale=w=80:h=44 -frames:v 1 -f null - \
  > "$WORK_ROOT/desktop-zscale-smoke.log" 2>&1

if command -v ldd >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  ldd "$ffmpeg" > "$WORK_ROOT/desktop-ffmpeg-ldd.txt"
  if rg -q 'lib(x264|zimg)' "$WORK_ROOT/desktop-ffmpeg-ldd.txt"; then
    die "desktop ffmpeg must link pinned x264/zimg statically"
  fi
fi

if command -v objdump >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  for binary in "$ffmpeg" "$ffprobe"; do
    glibc_report="$WORK_ROOT/$(basename "$binary")-glibc-symbols.txt"
    objdump -T "$binary" | rg -o 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu > "$glibc_report" || true
    python3 - "$binary" "$glibc_report" "$DESKTOP_LINUX_MAX_GLIBC" <<'PY'
import sys

binary, report, max_allowed = sys.argv[1:]

def parse(version):
    major, minor = version.split(".", 1)
    return int(major), int(minor)

with open(report, encoding="utf-8") as handle:
    versions = sorted(
        {line.strip().removeprefix("GLIBC_") for line in handle if line.strip()},
        key=parse,
    )
if not versions:
    raise SystemExit(0)
highest = versions[-1]
if parse(highest) > parse(max_allowed):
    raise SystemExit(
        f"{binary} requires GLIBC_{highest}; max allowed is GLIBC_{max_allowed}"
    )
PY
  done
fi

python3 "$REPO_ROOT/tests/desktop_cli/verify_media.py" \
  --ffmpeg "$ffmpeg" \
  --ffprobe "$ffprobe" \
  --work-dir "$WORK_ROOT" \
  --target "$(basename "$artifact_dir")"

log "desktop CLI verification complete for $artifact_dir"
