# Mobile FFtools Patch

Patch file:

```text
patches/ffmpeg-8.1/ffmpeg-ffi-boundary.patch
```

This is the only FFmpeg source patch. It is mobile-only and limited to the
`fftools` command boundary:

- `fftools/ffmpeg.c`
- `fftools/ffmpeg_opt.c`

It does not patch `libavcodec`, `libavformat`, `libavfilter`, `libavutil`, or
desktop CLI behavior.

## Why It Exists

Mobile needs to run FFmpeg inside the app process. Upstream FFmpeg exposes the
command through CLI `main(...)`, which assumes a fresh process per run. The app
needs a callable API that can:

- execute one argv command
- report progress
- cancel cooperatively
- clean up and run another command later
- avoid mutating host process signal handlers

That is what this patch adds.

## Patch Map

### C ABI

Added in `fftools/ffmpeg.c`:

- `FfmpegFfiSession`
- `ffmpeg_session_new`
- `ffmpeg_session_free`
- `ffmpeg_execute`
- `ffmpeg_cancel`

`FfmpegFfiSession` remains private to the patched source. Public callers only
see the opaque typedef in `include/ffmpeg_ffi.h`.

### Process-Global Execute Lock

`ffmpeg_execute(...)` is guarded by one `atomic_flag`. A second concurrent
command returns `EBUSY`.

Reason: FFmpeg command code keeps file-scope state. Dart isolates share the same
loaded native library, so command execution must also be serialized in the
Flutter wrapper.

### Per-Run State Reset

`ffmpeg_ffi_reset_run_state(...)` resets command globals in `fftools/ffmpeg.c`.

Option globals are reset before each embedded run. Most are reset directly by
`ffmpeg_ffi_reset_run_state(...)`; the static overwrite flags in
`fftools/ffmpeg_opt.c` are reset by `ffmpeg_ffi_reset_options_state(...)`:

- `file_overwrite`
- `no_file_overwrite`
- `stdin_interaction`

This fixes the important embedded-process leak where one `-y` or `-n` command
could change overwrite behavior for a later command.

The audited state list below is checked against both the pinned upstream source
and the patched reset functions by `scripts/validate-fftools-state-audit.sh`.

### Signal And Terminal Safety

The SIGTERM/SIGPIPE fix is in this same patch, in `fftools/ffmpeg.c`.

The patch sets `ffmpeg_ffi_embedded_mode` when `ffmpeg_execute(...)` is called
with a non-null session. In embedded mode:

- `term_init()` returns immediately
- FFmpeg does not install process-wide `SIGINT`, `SIGTERM`, or `SIGQUIT`
  handlers
- FFmpeg does not set `SIGPIPE` to `SIG_IGN`
- stdin keyboard handling is skipped
- the repeated-signal hard-exit path does not call `exit(123)`

The CLI `main(...)` path calls `ffmpeg_execute(NULL, ...)`, so normal FFmpeg CLI
signal behavior is unchanged for desktop executables.

Runtime proof lives in `tests/ffi_harness/ffmpeg_ffi_harness.c`: the harness
installs host `SIGTERM` and `SIGPIPE` handlers, runs `ffmpeg_execute(...)`, and
asserts the handlers are still present afterward.

### Cancellation

`ffmpeg_cancel(session)` sets an atomic cancel flag. The patch observes it in:

- `decode_interrupt_cb(...)`, so blocking FFmpeg I/O can abort
- the main transcode scheduler loop, so normal scheduler cleanup runs
- final return-code mapping, so cancellation returns `255`

The patch does not kill threads or use `longjmp`. Cancellation is cooperative.
The harness covers normal MP4 cancellation, immediate cancellation, and a
Photos-shaped HLS/AES single-file cancel command.

### Progress Callback

`print_report(...)` forwards timestamp progress to the session callback. Its
old local statics are moved to resettable file-scope variables so a later run
does not inherit progress timing state.

Callbacks are suppressed after teardown begins. The harness asserts there are no
late callbacks after `ffmpeg_execute(...)` returns.

## Out Of Scope

- Android 16 KB page-size support. That is linker flags plus package validation.
- Metadata probing patches. `ffmpeg_probe_media_json(...)` is implemented in
  `src/ffmpeg_ffi_probe.c` using direct libavformat/libavcodec APIs.
- Arbitrary `fftools/ffprobe.c` command execution.
- Hardware encode/decode.
- Desktop subprocess cancellation.

## State Audit

`ffmpeg_execute(...)` runs FFmpeg command code repeatedly in one app process.
Upstream CLI runs get a fresh process, so command file-scope state must be
classified for mobile.

`scripts/validate-fftools-state-audit.sh` checks that every audited symbol below
still matches the pinned FFmpeg source.

Scope:

- included: command objects used by mobile `libffmpeg_ffi`
- excluded: `ffplay`, `ffprobe` command wrappers
- metadata probing: `src/ffmpeg_ffi_probe.c`, not `fftools/ffprobe.c`

### Reset Before Each Embedded Run

Reset by `ffmpeg_ffi_reset_run_state(...)` in patched `fftools/ffmpeg.c`:

- `nb_output_dumped`, `current_time`, `progress_avio`
- `input_files`, `nb_input_files`
- `output_files`, `nb_output_files`
- `filtergraphs`, `nb_filtergraphs`
- `decoders`, `nb_decoders`
- `received_sigterm`, `received_nb_signals`
- `transcode_init_done`, `ffmpeg_exited`
- `copy_ts_first_pts`
- `ffmpeg_ffi_report_last_time`, `ffmpeg_ffi_report_first_report`

Reset by `ffmpeg_ffi_reset_options_state(...)` in patched
`fftools/ffmpeg_opt.c`:

- `filter_hw_device`, `vstats_filename`
- `dts_delta_threshold`, `dts_error_threshold`
- `video_sync_method`, `frame_drop_threshold`
- `do_benchmark`, `do_benchmark_all`
- `do_hex_dump`, `do_pkt_dump`
- `copy_ts`, `start_at_zero`, `copy_tb`
- `debug_ts`, `exit_on_error`, `abort_on_flags`
- `print_stats`, `stdin_interaction`, `max_error_rate`
- `filter_nbthreads`, `filter_complex_nbthreads`, `filter_buffered_frames`
- `vstats_version`, `print_graphs`
- `print_graphs_file`, `print_graphs_format`
- `auto_conversion_filters`, `stats_period`
- `file_overwrite`, `no_file_overwrite`
- `ignore_unknown_streams`, `copy_unknown_streams`, `recast_media`

Embedded runs force `stdin_interaction = 0`.

### Cleaned By Upstream Cleanup

`fftools/cmdutils.c` via `uninit_opts(...)`:

- `sws_dict`, `swr_opts`, `format_opts`, `codec_opts`

`fftools/ffmpeg_hw.c` via `hw_device_free_all(...)`:

- `nb_hw_devices`, `hw_devices`

`fftools/ffmpeg_mux_init.c` via `of_enc_stats_close(...)`:

- `enc_stats_files`, `nb_enc_stats_files`

`fftools/ffmpeg.c` via command cleanup:

- `vstats_file`

### Host Process State

`fftools/ffmpeg.c`:

- `oldtty`, `restore_tty`, `int_cb`

Embedded mode skips CLI terminal/signal initialization. In practice this means
`ffmpeg_execute(...)` must not replace host `SIGTERM` handlers or ignore
`SIGPIPE`. The runtime harness verifies both.

`int_cb` is const state; its callback observes the active session cancel flag.

### Benign Or Unsupported

`fftools/cmdutils.c`:

- `hide_banner`
- `win32_argv_utf8`, `win32_argc`

`hide_banner` is log-only. `win32_argv_utf8` and `win32_argc` are Windows-only
argv conversion state and are inactive on Android/iOS.

`fftools/opt_common.c`:

- `report_file`, `report_file_level`
- `warned_cfg`

Embedded mobile commands must not use `-report` or `FFREPORT` until explicit
cleanup/reset is added for `report_file` and `report_file_level`. `warned_cfg`
is a one-time warning flag, not media state.

## Mobile Release Proof

The mobile runtime harness must pass on Android device and iOS simulator before
mobile release promotion. Physical iOS device coverage still needs a signed app
or Flutter harness.
