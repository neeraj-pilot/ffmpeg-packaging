"""Serve browser checks after npm ci --ignore-scripts in tests/wasm."""

import argparse
import json
import shutil
import subprocess
import tempfile
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--core", type=Path, required=True, help="Built Wasm directory")
parser.add_argument("--ffmpeg", required=True, help="Native FFmpeg for the generated fixture")
args = parser.parse_args()
tests = Path(__file__).resolve().parent

with tempfile.TemporaryDirectory(prefix="ffmpeg-wasm-tests-") as directory:
    root = Path(directory)
    (root / "core").symlink_to(args.core.resolve(), target_is_directory=True)
    wrapper = tests / "node_modules/@ffmpeg/ffmpeg/dist/umd"
    if not wrapper.is_dir():
        parser.error("Run npm ci --ignore-scripts in tests/wasm first")
    (root / "wrapper-umd").symlink_to(wrapper, target_is_directory=True)
    for filename in ("index.html", "verify.js"):
        shutil.copyfile(tests / filename, root / filename)
    subprocess.run([
        args.ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10",
        "-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:v", "libx264",
        "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", str(root / "source.mp4"),
    ], check=True)

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(root), **kwargs)

        def end_headers(self):
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", "default-src 'self'; "
                             "script-src 'self' 'wasm-unsafe-eval' http://127.0.0.1:8768/core/ffmpeg-core.js; "
                             "worker-src 'self' blob:; connect-src 'self' http://127.0.0.1:8768; "
                             "style-src 'self' 'unsafe-inline'; img-src 'self' blob:; media-src 'self' blob:")
            super().end_headers()

        def log_message(self, *_):
            pass

        def do_POST(self):
            if self.path != "/report":
                self.send_error(404)
                return
            report = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            print(json.dumps(report, indent=2), flush=True)
            self.send_response(204)
            self.end_headers()

    with ThreadingHTTPServer(("127.0.0.1", 8768), Handler) as assets:
        threading.Thread(target=assets.serve_forever, daemon=True).start()
        with ThreadingHTTPServer(("127.0.0.1", 8767), Handler) as page:
            print("Open http://127.0.0.1:8767/ and run both asset modes.", flush=True)
            try:
                page.serve_forever()
            except KeyboardInterrupt:
                pass
        assets.shutdown()
