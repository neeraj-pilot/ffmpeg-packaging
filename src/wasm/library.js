// FFmpeg's scheduler needs pthreads. Keep codec/filter auto-threading within
// the pre-created worker pool, including x264 and dav1d's own CPU detection.
addToLibrary({
  emscripten_num_logical_cores: () => 1,
  ffmpeg_wasm_progress: (progress, time) =>
    Module["progress"]({ progress, time }),
});
