# Patches

Production patches live here as reviewable files.

Current patch:

```text
patches/ffmpeg-8.1/ffmpeg-ffi-boundary.patch
```

Patch rules:

- keep the patch limited to the mobile `fftools` command boundary
- keep `FfmpegFfiSession` opaque in the public header
- keep command execution process-global and protected by an atomic lock
- do not patch FFmpeg core libraries for wrapper behavior
- keep metadata probing in `src/ffmpeg_ffi_probe.c`
- do not patch desktop CLI artifacts
- keep cancellation, progress, and run-state reset behavior covered by the
  mobile runtime harness
- split into a second patch only if a future change touches FFmpeg core
  libraries or non-wrapper behavior

See `../docs/mobile-fftools-patch.md` for the mobile patch rationale and
command-state audit.
