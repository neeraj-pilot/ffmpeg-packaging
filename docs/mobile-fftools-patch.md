# Mobile FFtools Patch

Patch file:

```text
patches/ffmpeg-9.0/ffmpeg-runtime.patch
```

The mobile runtime and Wasm core share this patch. It is limited to the
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

- `FfmpegSession`
- `ffmpeg_session_new`
- `ffmpeg_session_free`
- `ffmpeg_session_output`
- `ffmpeg_execute`
- `ffmpeg_cancel`

`FfmpegSession` remains private to the patched source. Public callers only
see the opaque typedef in `include/ffmpeg_runtime.h`.

### Process-Global Execute Lock

`ffmpeg_execute(...)` is guarded by one `atomic_flag`. A second concurrent
command returns `EBUSY`.

Reason: FFmpeg command code keeps file-scope state. Dart isolates share the same
loaded native library, so command execution must also be serialized in the
Flutter wrapper.

### Per-Run State Reset

`ffmpeg_runtime_reset_run_state(...)` resets command globals in `fftools/ffmpeg.c`.

Option globals are reset before each embedded run. Most are reset directly by
`ffmpeg_runtime_reset_run_state(...)`; the static overwrite flags in
`fftools/ffmpeg_opt.c` are reset by `ffmpeg_runtime_reset_options_state(...)`:

- `file_overwrite`
- `no_file_overwrite`
- `stdin_interaction`

This fixes the important embedded-process leak where one `-y` or `-n` command
could change overwrite behavior for a later command.

`scripts/validate-fftools-state-audit.sh` owns the audited state inventory and
checks the pinned upstream globals against the patched reset functions.

### Signal And Terminal Safety

The SIGTERM/SIGPIPE fix is in this same patch, in `fftools/ffmpeg.c`.

The patch sets `ffmpeg_runtime_embedded_mode` when `ffmpeg_execute(...)` is called
with a non-null session. In embedded mode:

- `term_init()` returns immediately
- FFmpeg does not install process-wide `SIGINT`, `SIGTERM`, or `SIGQUIT`
  handlers
- FFmpeg does not set `SIGPIPE` to `SIG_IGN`
- stdin keyboard handling is skipped
- the repeated-signal hard-exit path does not call `exit(123)`

Wasm adds `patches/ffmpeg-9.0/wasm.patch` on top of this patch and calls
`ffmpeg_execute(NULL, ...)`. Desktop CLI builds apply neither FFmpeg patch.

Runtime proof lives in `tests/runtime/ffmpeg_runtime_harness.c`: the harness
installs host `SIGTERM` and `SIGPIPE` handlers, runs `ffmpeg_execute(...)`, and
asserts the handlers are still present afterward.

### Cancellation

`ffmpeg_cancel(session)` sets an atomic cancel flag. The patch observes it in:

- `decode_interrupt_cb(...)`, so blocking FFmpeg I/O can abort
- the main transcode scheduler loop, so normal scheduler cleanup runs
- final return-code mapping, so cancellation returns `255`

The patch does not kill threads or use `longjmp`. Cancellation is cooperative.
The harness covers normal MP4 cancellation, immediate cancellation, stalled
input and output I/O, and a Photos-shaped HLS/AES single-file cancel command.

A session is single-use. A cancellation requested before `ffmpeg_execute`
starts is retained and returns `255` without opening its output. The caller
must wait for execution to return before freeing the session.

### Progress Callback

`print_report(...)` forwards timestamp progress to the session callback. Its
old local statics are moved to resettable file-scope variables so a later run
does not inherit progress timing state.

Callbacks are suppressed after teardown begins. The harness asserts there are no
late callbacks after `ffmpeg_execute(...)` returns.

### Diagnostics

The wrapper installs its own libav log callback once. Android and iOS both
statically contain their media libraries and hide their symbols, so this does
not replace media_kit's callback. Warnings and errors are kept in an 8191-byte
tail owned by the active session. `ffmpeg_session_output` returns that buffer
after execution; the caller copies it before freeing the session.

The callback uses a mutex when accessing the active session. Probe operations
may run concurrently, so their warnings can appear in this diagnostic tail.
Probe failure is also reported separately by its return code. Log callbacks
stay in native code; Dart copies the diagnostic string after completion.
Each command resets the log level before parsing its own options.

## Out Of Scope

- Android 16 KB page-size support. That is linker flags plus package validation.
- Metadata probing patches. `ffmpeg_probe_media_json(...)` is implemented in
  `src/ffmpeg_runtime_probe.c` using direct libavformat/libavcodec APIs.
- Arbitrary `fftools/ffprobe.c` command execution.
- Hardware encode/decode.
- Desktop subprocess cancellation.

## State Audit

The audit script classifies command globals from the pinned, unpatched source.
Every classified global must be reset unless explicitly exempted because
upstream cleanup owns it, it is host/constant state, or it is inactive/log-only.
The two progress globals introduced by the runtime patch are checked separately.

Embedded mobile commands must not use `-report` or `FFREPORT` until explicit
cleanup/reset is added for report state. The mobile API supports media processing
commands, not CLI help/version printers that replace libav's log callback.

On an FFmpeg upgrade, review initializer values as well as added globals. The
static audit checks reset assignments, not equivalence to upstream defaults.
Wasm also resets ffprobe options and restores its log callback; repeated-probe
browser tests cover that separate path.

## Wasm

The additional Wasm patch makes ffprobe return through cleanup and resets its
per-run options. Timeouts use the existing interrupt/cancellation path. The JS
bridge owns argv allocations; a thrown runtime error requires terminating and
reloading the worker. Ordinary nonzero command results remain reusable.

Changes to the shared runtime patch need both the mobile harness and browser
checks. Changes confined to Wasm do not require rebuilding mobile artifacts.

## Mobile Release Proof

The mobile runtime harness must pass on Android device and iOS simulator before
mobile release promotion. Physical iOS device coverage still needs a signed app
or Flutter harness.
