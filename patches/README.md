# Patches

- `ffmpeg-9.0/ffmpeg-runtime.patch` adds the reusable mobile command boundary.
  Wasm shares it and applies `ffmpeg-9.0/wasm.patch` afterward for ffprobe,
  timeout, and progress support. Desktop CLI builds apply neither patch.
- `x264/encoder-open-cleanup.patch` releases parameter strings when opening an
  encoder fails. All builds apply it; provenance is in
  [the dependency review](../docs/dependency-review.md).

Keep runtime patches confined to `fftools`; metadata probing uses direct libav
APIs in `src/ffmpeg_runtime_probe.c`. Preserve the opaque session ABI, serialized
execution, cancellation, and host-process safety. Shared runtime changes need
mobile harness and browser verification.

See [runtime contracts](../docs/mobile-fftools-patch.md).
