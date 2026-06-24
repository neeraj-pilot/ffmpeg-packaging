#!/usr/bin/env python3
"""Functional desktop FFmpeg checks for generated CLI artifacts."""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("FFMPEG_DESKTOP_TEST_TIMEOUT", "90")),
    )
    return parser.parse_args()


def run(command: list[str], *, timeout: int, stdout: Path | None = None) -> str:
    kwargs = {
        "stderr": subprocess.PIPE,
        "text": True,
        "timeout": timeout,
        "check": False,
    }
    if stdout is None:
        kwargs["stdout"] = subprocess.PIPE
    else:
        stdout.parent.mkdir(parents=True, exist_ok=True)
        handle = stdout.open("w", encoding="utf-8")
        kwargs["stdout"] = handle
    try:
        completed = subprocess.run(command, **kwargs)
    except subprocess.TimeoutExpired as exc:
        raise SystemExit(f"command timed out after {timeout}s: {command!r}") from exc
    finally:
        if stdout is not None:
            handle.close()
    if completed.returncode != 0:
        raise SystemExit(
            f"command failed with {completed.returncode}: {command!r}\n"
            f"{completed.stderr}"
        )
    return completed.stdout if isinstance(completed.stdout, str) else ""


def assert_contains(haystack: str, needle: str, label: str) -> None:
    if needle not in haystack:
        raise SystemExit(f"{label} missing {needle}")


def verify_buildconf(ffmpeg: str, work_dir: Path, timeout: int) -> None:
    version = run([ffmpeg, "-version"], timeout=timeout)
    (work_dir / "ffmpeg-version.txt").write_text(version, encoding="utf-8")
    buildconf = run([ffmpeg, "-buildconf"], timeout=timeout)
    (work_dir / "ffmpeg-buildconf.txt").write_text(buildconf, encoding="utf-8")
    for flag in ("--enable-libx264", "--enable-libzimg", "--enable-gpl"):
        assert_contains(buildconf, flag, "ffmpeg buildconf")


def make_mp4(ffmpeg: str, sample: Path, timeout: int) -> None:
    run(
        [
            ffmpeg,
            "-hide_banner",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=duration=2:size=320x180:rate=15",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=2",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            str(sample),
        ],
        timeout=timeout,
    )
    if sample.stat().st_size <= 0:
        raise SystemExit("generated MP4 is empty")


def verify_probe(ffprobe: str, sample: Path, work_dir: Path, timeout: int) -> None:
    probe_json = run(
        [
            ffprobe,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(sample),
        ],
        timeout=timeout,
    )
    (work_dir / "ffprobe.json").write_text(probe_json, encoding="utf-8")
    data = json.loads(probe_json)
    streams = data.get("streams")
    if not isinstance(streams, list) or not streams:
        raise SystemExit("ffprobe JSON missing streams")
    video_streams = [s for s in streams if s.get("codec_type") == "video"]
    if len(video_streams) != 1:
        raise SystemExit(f"expected one video stream, found {len(video_streams)}")
    video = video_streams[0]
    if video.get("codec_name") != "h264":
        raise SystemExit(f"expected h264 video, got {video.get('codec_name')}")
    if video.get("width") != 320 or video.get("height") != 180:
        raise SystemExit(f"unexpected dimensions: {video.get('width')}x{video.get('height')}")
    fmt = data.get("format")
    if not isinstance(fmt, dict):
        raise SystemExit("ffprobe JSON missing format")
    duration = float(fmt.get("duration") or 0)
    if duration <= 0:
        raise SystemExit(f"unexpected duration: {duration}")


def verify_hls(ffmpeg: str, sample: Path, hls_dir: Path, timeout: int) -> None:
    hls_dir.mkdir(parents=True, exist_ok=True)
    playlist = hls_dir / "output.m3u8"
    segment = hls_dir / "output.ts"
    key = hls_dir / "output.m3u8.key"
    key_info = hls_dir / "output.m3u8.key-info"
    key_bytes = bytes(range(16))
    key_uri = "data:text/plain;base64," + base64.b64encode(key_bytes).decode("ascii")
    key.write_bytes(key_bytes)
    key_info.write_text(f"{key_uri}\n{key}\n", encoding="utf-8")
    run(
        [
            ffmpeg,
            "-hide_banner",
            "-y",
            "-i",
            str(sample),
            "-vf",
            "scale='if(lt(iw,ih),min(720,iw),-2)':'if(lt(iw,ih),-2,min(720,ih))',fps=30,format=yuv420p",
            "-c:v",
            "libx264",
            "-maxrate",
            "2000k",
            "-bufsize",
            "4000k",
            "-c:a",
            "aac",
            "-f",
            "hls",
            "-hls_key_info_file",
            str(key_info),
            "-hls_list_size",
            "0",
            "-hls_flags",
            "single_file",
            str(playlist),
        ],
        timeout=timeout,
    )
    playlist_bytes = playlist.read_bytes()
    if b"\r\n" in playlist_bytes:
        raise SystemExit("HLS playlist uses CRLF newlines")
    playlist_text = playlist_bytes.decode("utf-8")
    for expected in (
        "#EXTM3U",
        "#EXT-X-KEY:METHOD=AES-128",
        key_uri,
        "#EXT-X-BYTERANGE",
        "output.ts",
    ):
        assert_contains(playlist_text, expected, "HLS playlist")
    if not segment.is_file() or segment.stat().st_size <= 0:
        raise SystemExit("HLS single-file segment is missing or empty")


def verify_tonemap(ffmpeg: str, work_dir: Path, timeout: int) -> None:
    run(
        [
            ffmpeg,
            "-hide_banner",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=duration=1:size=160x90:rate=5",
            "-vf",
            (
                "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,"
                "zscale=transfer=linear:npl=100,"
                "format=gbrpf32le,"
                "tonemap=tonemap=hable:desat=0,"
                "zscale=primaries=709:transfer=709:matrix=709,"
                "format=yuv420p"
            ),
            "-frames:v",
            "1",
            "-f",
            "null",
            "-",
        ],
        timeout=timeout,
        stdout=work_dir / "tonemap-smoke.log",
    )


def main() -> int:
    args = parse_args()
    ffmpeg = str(Path(args.ffmpeg))
    ffprobe = str(Path(args.ffprobe))
    work_dir = Path(args.work_dir) / f"desktop-media-{args.target}"
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)
    if not Path(ffmpeg).is_file():
        raise SystemExit(f"missing ffmpeg: {ffmpeg}")
    if not Path(ffprobe).is_file():
        raise SystemExit(f"missing ffprobe: {ffprobe}")

    verify_buildconf(ffmpeg, work_dir, args.timeout)
    sample = work_dir / "sample.mp4"
    make_mp4(ffmpeg, sample, args.timeout)
    verify_probe(ffprobe, sample, work_dir, args.timeout)
    verify_hls(ffmpeg, sample, work_dir / "hls", args.timeout)
    verify_tonemap(ffmpeg, work_dir, args.timeout)
    print(f"desktop media verification complete for {args.target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
