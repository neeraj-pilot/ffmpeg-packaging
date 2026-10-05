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

if [ "$(uname -s)" = "Darwin" ]; then
  for binary in "$ffmpeg" "$ffprobe"; do
    load_commands="$WORK_ROOT/$(basename "$binary")-load-commands.txt"
    otool -l "$binary" > "$load_commands"
    python3 - "$binary" "$load_commands" "$DESKTOP_MACOS_MIN_VERSION" <<'PY'
import re
import sys

binary, report, maximum = sys.argv[1:]
with open(report, encoding="utf-8") as handle:
    versions = re.findall(r"^\s+minos ([0-9.]+)$", handle.read(), re.M)
def numeric_version(value):
    return tuple(map(int, (value.split(".") + ["0", "0"])[:3]))
if not versions or any(numeric_version(v) > numeric_version(maximum) for v in versions):
    raise SystemExit(f"{binary} has macOS minimum versions {versions}; max allowed is {maximum}")
PY
  done
fi

if command -v ldd >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  ldd "$ffmpeg" > "$WORK_ROOT/desktop-ffmpeg-ldd.txt"
  if rg -q 'lib(x264|zimg|dav1d)' "$WORK_ROOT/desktop-ffmpeg-ldd.txt"; then
    die "desktop ffmpeg must link pinned x264/zimg/dav1d statically"
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
