const result = document.querySelector("#results");
const logs = document.querySelector("#logs");
const status = document.querySelector("#status");
const preview = document.querySelector("#preview");
const run = document.querySelector("#run");
document.querySelector("#environment").textContent =
  `${navigator.userAgent}\nCross-origin isolated: ${crossOriginIsolated}`;
function assert(value, message) {
  if (!value) throw new Error(message);
}
run.onclick = async () => {
  run.disabled = true;
  result.textContent = "";
  logs.textContent = "";
  preview.replaceChildren();
  const selected = document.querySelector("#build").value;
  const { FFmpeg, FFFSType } = FFmpegWASM;
  const ffmpeg = new FFmpeg();
  const messages = [];
  const cancel = document.querySelector("#cancel");
  cancel.disabled = false;
  cancel.onclick = () => ffmpeg.terminate();
  ffmpeg.on("log", ({ message }) => {
    messages.push(message);
    logs.textContent += `${message}\n`;
  });
  const report = {
    browser: navigator.userAgent,
    isolated: crossOriginIsolated,
    tests: [],
  };
  const check = async (name, fn) => {
    status.textContent = name;
    const started = performance.now();
    let timer;
    try {
      await Promise.race([
        fn(),
        new Promise((_, reject) => {
          timer = setTimeout(() => {
            ffmpeg.terminate();
            reject(new Error("Test exceeded 30 seconds"));
          }, 30000);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
    const milliseconds = Math.round(performance.now() - started);
    report.tests.push({ name, milliseconds, passed: true });
    result.textContent += `PASS  ${name} (${milliseconds} ms)\n`;
  };
  const probe = async (args, file = "/probe.json") => {
    const code = await ffmpeg.ffprobe([
      "-v",
      "error",
      ...args,
      "-of",
      "json",
      "-o",
      file,
      "/mount/source's café.mp4",
    ]);
    assert(code === 0, `ffprobe returned ${code}`);
    return JSON.parse(await ffmpeg.readFile(file, "utf8"));
  };
  try {
    report.build = selected;
    const base =
      selected === "cross"
        ? "http://127.0.0.1:8768/core/"
        : new URL("./core/", location.href).href;
    await check("Load core through existing @ffmpeg/ffmpeg wrapper", () =>
      ffmpeg.load({
        coreURL: `${base}ffmpeg-core.js`,
        wasmURL: `${base}ffmpeg-core.wasm`,
      }),
    );
    await check("Read engine version", async () => {
      await ffmpeg.exec(["-version"]);
      assert(
        messages.some((line) => line.includes("9.0.2")),
        "Unexpected FFmpeg version",
      );
    });
    await check(
      "Mount a File with spaces, apostrophe and Unicode",
      async () => {
        const blob = await (await fetch("./source.mp4")).blob();
        await ffmpeg.createDir("/mount");
        await ffmpeg.mount(
          FFFSType.WORKERFS,
          { files: [new File([blob], "source's café.mp4")] },
          "/mount",
        );
      },
    );
    await check("Probe duration and stream metadata", async () => {
      const json = await probe(["-show_format", "-show_streams"]);
      assert(Number(json.format.duration) === 2, "Duration differs");
      const video = json.streams.find(
        (stream) => stream.codec_type === "video",
      );
      assert(
        video.width === 160 &&
          video.height === 90 &&
          video.codec_name === "h264",
        "Video metadata differs",
      );
    });
    await check("Generate a scaled JPEG thumbnail", async () => {
      const code = await ffmpeg.exec([
        "-i",
        "/mount/source's café.mp4",
        "-vf",
        "scale=80:-2",
        "-frames:v",
        "1",
        "/thumbnail.jpg",
      ]);
      assert(code === 0, `Thumbnail returned ${code}`);
      const data = await ffmpeg.readFile("/thumbnail.jpg");
      assert(data.length > 100, "Empty thumbnail");
      const image = new Image();
      image.src = URL.createObjectURL(new Blob([data], { type: "image/jpeg" }));
      await image.decode();
      assert(image.naturalWidth === 80, "Wrong thumbnail dimensions");
      preview.append(image);
    });
    await check("Encode H.264/AAC with crop, rotation and speed", async () => {
      const code = await ffmpeg.exec([
        "-i",
        "/mount/source's café.mp4",
        "-vf",
        "crop=120:80,transpose=1,setpts=0.5*PTS",
        "-af",
        "atempo=2",
        "-c:v",
        "libx264",
        "-c:a",
        "aac",
        "/edited.mp4",
      ]);
      assert(code === 0, `Encode returned ${code}`);
      const data = await ffmpeg.readFile("/edited.mp4");
      assert(data.length > 1000, "Empty encode");
    });
    await check(
      "Failed command does not prevent the next command",
      async () => {
        assert(
          (await ffmpeg.exec(["-i", "/absent.mp4", "-f", "null", "-"])) !== 0,
          "Missing input unexpectedly succeeded",
        );
        assert(
          (await ffmpeg.exec([
            "-i",
            "/mount/source's café.mp4",
            "-frames:v",
            "1",
            "-f",
            "null",
            "-",
          ])) === 0,
          "Reentry failed",
        );
      },
    );
    await check(
      "Probe again with only format.duration (no stale options)",
      async () => {
        const json = await probe(["-show_entries", "format=duration"]);
        assert(Number(json.format.duration) === 2, "Second duration differs");
        assert(
          !json.streams && Object.keys(json.format).length === 1,
          "ffprobe options leaked from previous command",
        );
      },
    );
    {
      await check("ffprobe error cleanup permits the next probe", async () => {
        for (const args of [
          ["-c:v", "missing_decoder"],
          ["-of", "json=missing_option=1"],
        ]) {
          assert(
            (await ffmpeg.ffprobe([
              ...args,
              "-i",
              "/mount/source's café.mp4",
              "-show_format",
              "-o",
              "/bad.json",
            ])) !== 0,
            "Invalid probe unexpectedly succeeded",
          );
          const json = await probe(["-show_entries", "format=duration"]);
          assert(Number(json.format.duration) === 2, "Probe did not recover");
        }
      });
      await check("Execution timeout and progress callbacks", async () => {
        const updates = [];
        ffmpeg.on("progress", (update) => updates.push(update));
        assert(
          (await ffmpeg.exec(
            [
              "-stream_loop",
              "-1",
              "-i",
              "/mount/source's café.mp4",
              "-t",
              "1000",
              "-c:v",
              "libx264",
              "-f",
              "null",
              "-",
            ],
            30,
          )) !== 0,
          "Timeout was ignored",
        );
        assert(
          (await ffmpeg.exec([
            "-i",
            "/mount/source's café.mp4",
            "-frames:v",
            "1",
            "-f",
            "null",
            "-",
          ])) === 0,
          "Timeout state leaked",
        );
        assert(
          updates.some((update) => update.time > 0),
          "No progress was reported",
        );
      });
    }
    await ffmpeg.unmount("/mount");
    await ffmpeg.deleteDir("/mount");
    status.textContent = `All ${report.tests.length} smoke tests passed`;
  } catch (error) {
    status.textContent = "Test failed";
    report.error = String(error);
    result.textContent += `FAIL  ${error}\n`;
  } finally {
    ffmpeg.terminate();
    cancel.disabled = true;
    run.disabled = false;
    await fetch("/report", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(report),
    });
  }
};
