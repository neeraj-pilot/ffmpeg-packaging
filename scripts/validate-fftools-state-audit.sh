#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ffmpeg_tree="${1:-$(ffmpeg_source_dir)}"
audit_doc="$REPO_ROOT/docs/mobile-fftools-patch.md"

require_dir "$ffmpeg_tree/fftools"
require_file "$audit_doc"
require_cmd python3

python3 - "$ffmpeg_tree" "$audit_doc" <<'PY'
import re
import sys
from pathlib import Path

ffmpeg_tree = Path(sys.argv[1])
audit_doc = Path(sys.argv[2])

expected = {
    "cmdutils.c": {
        "sws_dict",
        "swr_opts",
        "format_opts",
        "codec_opts",
        "hide_banner",
        "win32_argv_utf8",
        "win32_argc",
    },
    "ffmpeg.c": {
        "vstats_file",
        "nb_output_dumped",
        "current_time",
        "progress_avio",
        "input_files",
        "nb_input_files",
        "output_files",
        "nb_output_files",
        "filtergraphs",
        "nb_filtergraphs",
        "decoders",
        "nb_decoders",
        "oldtty",
        "restore_tty",
        "received_sigterm",
        "received_nb_signals",
        "transcode_init_done",
        "ffmpeg_exited",
        "copy_ts_first_pts",
        "int_cb",
    },
    "ffmpeg_hw.c": {
        "nb_hw_devices",
        "hw_devices",
    },
    "ffmpeg_mux_init.c": {
        "enc_stats_files",
        "nb_enc_stats_files",
    },
    "ffmpeg_opt.c": {
        "filter_hw_device",
        "vstats_filename",
        "dts_delta_threshold",
        "dts_error_threshold",
        "video_sync_method",
        "frame_drop_threshold",
        "do_benchmark",
        "do_benchmark_all",
        "do_hex_dump",
        "do_pkt_dump",
        "copy_ts",
        "start_at_zero",
        "copy_tb",
        "debug_ts",
        "exit_on_error",
        "abort_on_flags",
        "print_stats",
        "stdin_interaction",
        "max_error_rate",
        "filter_nbthreads",
        "filter_complex_nbthreads",
        "filter_buffered_frames",
        "vstats_version",
        "print_graphs",
        "print_graphs_file",
        "print_graphs_format",
        "auto_conversion_filters",
        "stats_period",
        "file_overwrite",
        "no_file_overwrite",
        "ignore_unknown_streams",
        "copy_unknown_streams",
        "recast_media",
    },
    "opt_common.c": {
        "report_file",
        "report_file_level",
        "warned_cfg",
    },
}

type_re = re.compile(
    r"^(?:"
    r"const\s+AVIOInterruptCB|"
    r"struct\s+termios|"
    r"enum\s+VideoSyncMethod|"
    r"AVDictionary|FILE|int64_t|int|float|"
    r"atomic_uint|atomic_int|"
    r"BenchmarkTimeStamps|AVIOContext|"
    r"InputFile|OutputFile|FilterGraph|Decoder|"
    r"HWDevice|EncStatsFile|char"
    r")\b"
)


def normalize_decl(line):
    stripped = line.strip()
    if not stripped.endswith(";"):
        return None
    if stripped.startswith("#") or stripped.startswith("typedef "):
        return None
    if stripped.startswith("const ") and not stripped.startswith("const AVIOInterruptCB "):
        return None

    before_semicolon = stripped[:-1]
    if "(" in before_semicolon:
        return None
    while True:
        next_value = re.sub(r"^(static|volatile)\b\s*", "", before_semicolon)
        if next_value == before_semicolon:
            break
        before_semicolon = next_value
    if not type_re.match(before_semicolon):
        return None
    return before_semicolon


def names_from_decl(decl):
    without_initializer = decl.split("=", 1)[0]
    names = []
    for part in without_initializer.split(","):
        tokens = part.replace("*", " ").replace("[", " ").split()
        if tokens:
            names.append(tokens[-1])
    return names


actual = {}
for filename in sorted(expected):
    path = ffmpeg_tree / "fftools" / filename
    if not path.is_file():
        raise SystemExit(f"missing audited source file: {path}")
    names = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line[:1].isspace():
            continue
        decl = normalize_decl(line)
        if decl:
            names.update(names_from_decl(decl))
    actual[filename] = names

errors = []
for filename, expected_names in expected.items():
    missing = sorted(expected_names - actual[filename])
    unexpected = sorted(actual[filename] - expected_names)
    if missing:
        errors.append(f"{filename}: missing from scanner: {', '.join(missing)}")
    if unexpected:
        errors.append(f"{filename}: undocumented command state: {', '.join(unexpected)}")

doc_text = audit_doc.read_text(encoding="utf-8")
for filename, expected_names in expected.items():
    if filename not in doc_text:
        errors.append(f"{filename}: source file missing from audit doc")
    for name in sorted(expected_names):
        if f"`{name}`" not in doc_text:
            errors.append(f"{filename}: `{name}` missing from audit doc")

if errors:
    print("fftools state audit failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)

print("fftools state audit passed")
PY
