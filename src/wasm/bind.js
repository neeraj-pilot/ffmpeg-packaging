Module["ret"] = -1;
Module["logger"] = () => {};
Module["progress"] = () => {};
Module["print"] = (message) => Module["logger"]({ type: "stdout", message });
Module["printErr"] = (message) => Module["logger"]({ type: "stderr", message });
Module["setLogger"] = (logger) => (Module["logger"] = logger);
Module["setProgress"] = (progress) => (Module["progress"] = progress);
Module["setTimeout"] = (timeout) => Module["_ffmpeg_wasm_set_timeout"](timeout);
Module["reset"] = () => {
  Module["ret"] = -1;
};
let poisoned = false;
function runFFmpeg(entry, args) {
  if (poisoned)
    throw new Error("FFmpeg runtime failed; terminate and reload the worker");
  const pointers = [];
  let argv = 0;
  try {
    for (const value of args) {
      const size = Module["lengthBytesUTF8"](value) + 1;
      const ptr = Module["_malloc"](size);
      if (!ptr) throw new Error("FFmpeg argument allocation failed");
      pointers.push(ptr);
      Module["stringToUTF8"](value, ptr, size);
    }
    argv = Module["_malloc"]((pointers.length + 1) * 4);
    if (!argv) throw new Error("FFmpeg argument allocation failed");
    pointers.forEach((ptr, i) => Module["setValue"](argv + i * 4, ptr, "i32"));
    Module["setValue"](argv + pointers.length * 4, 0, "i32");
    Module["ret"] = entry(args.length, argv);
  } catch (error) {
    poisoned = true;
    throw error;
  } finally {
    // A trap can leave C state inconsistent. Only a new worker may use it again.
    if (!poisoned) {
      pointers.forEach((ptr) => Module["_free"](ptr));
      Module["_free"](argv);
    }
  }
  return Module["ret"];
}
Module["exec"] = (...args) =>
  runFFmpeg(Module["_ffmpeg_wasm_main"], [
    "./ffmpeg",
    "-nostdin",
    "-y",
    ...args,
  ]);
Module["ffprobe"] = (...args) =>
  runFFmpeg(Module["_ffprobe_wasm_main"], ["./ffprobe", ...args]);
if (!ENVIRONMENT_IS_PTHREAD) {
  if (!globalThis.crossOriginIsolated)
    throw new Error("FFmpeg requires cross-origin isolation (COOP/COEP)");
  const scriptURL = Module["mainScriptUrlOrBlob"];
  if (typeof scriptURL !== "string" || !scriptURL.includes("#"))
    throw new Error("Load this core through @ffmpeg/ffmpeg");
  const separator = scriptURL.lastIndexOf("#");
  const { wasmURL } = JSON.parse(atob(scriptURL.slice(separator + 1)));
  Module["locateFile"] = (path, prefix) =>
    path.endsWith(".wasm") ? wasmURL : prefix + path;
  const coreURL = scriptURL.slice(0, separator);
  if (new URL(coreURL).origin !== self.location.origin) {
    // Worker constructors require a same-origin URL even when importScripts
    // can load a cross-origin core. The pool is ready before postRun executes.
    const bootstrap = new Blob([`importScripts(${JSON.stringify(coreURL)});`], {
      type: "application/javascript",
    });
    const workerURL = URL.createObjectURL(bootstrap);
    Module["mainScriptUrlOrBlob"] = workerURL;
    Module["postRun"] = [() => URL.revokeObjectURL(workerURL)];
  }
}
