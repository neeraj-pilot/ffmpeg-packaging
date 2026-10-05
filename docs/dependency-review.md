# Dependency review — 2026-10-05

FFmpeg is pinned to 9.0.2 from its [official release directory](https://ffmpeg.org/releases/).
The downloaded archive's SHA-256 is recorded in `versions.env`. The upstream
signed tag `n9.0.2` resolves to `946fcce07b6dcd0331c8cc609192aeff5e1924f8`;
GitHub reports its signature as verified. This is a patch upgrade over the
previous uncommitted 9.0.1 packaging work. Its changelog includes decoder,
demuxer, and filter corrections relevant to processing user media.

Reviewed the [FFmpeg security list](https://ffmpeg.org/security.html), GitHub's
FFmpeg advisories, and OSV queries for FFmpeg 9.0.2 and the exact x264/zimg
commits in `versions.env`. The queries returned no matching records, but that
is not a complete statement of vulnerability coverage. In particular,
[CVE-2025-25467](https://security-tracker.debian.org/tracker/CVE-2025-25467)
has no affected-commit mapping in OSV and requires a separate assessment.

## x264 encoder initialization cleanup

The pinned x264 source duplicates parameter strings into `h->param`, whose
`opaque` member owns a separate allocation list. Its `x264_encoder_open` failure
label frees `h` without freeing that list. The successful close path already
calls `x264_param_cleanup(&h->param)` before freeing `h`.

The local patch adds the same cleanup before freeing a non-null `h` on the
initialization failure path. The initial allocation is zeroed, and the copied
parameter's `opaque` member is reset before strings are duplicated. This makes
the cleanup safe both before and after string allocation and does not free the
caller's parameter allocation list. Successful encoder initialization is
unchanged.

[Upstream MR 183](https://code.videolan.org/videolan/x264/-/merge_requests/183)
proposed this cleanup, but it is closed and has not been merged. This package
carries a local patch; it must not be described as an accepted upstream fix.
The assessment is based on source ownership, not a reproduced security exploit.

The separately reported FFmpeg RIST advisory, CVE-2026-75143, concerns the
optional librist protocol. The inspected Android configuration has
`CONFIG_LIBRIST=0`; this packaging does not enable librist.

## Windows ARM64 build environment

The native ARM64 job uses MSYS2's documented CLANGARM64 environment (LLVM,
UCRT, and libc++). `msys2/setup-msys2` is pinned to upstream v2.33.0 commit
`ec48f7c5447b3140e2b088413ae3a55687bccb6e`. Its GitHub advisory list returned
no published advisories on 2026-10-05. Toolchain packages come from MSYS2's
signed repositories; the media source pins above are unchanged. The release
gate rejects unpackaged compiler/media DLLs and runs the resulting executables
on a Windows ARM64 runner.

## Desktop AV1 decoder and build tools

The old ffmpeg-static 5.2.0 macOS binary (release b6.0) decodes AV1 in software
with libaom. The initial custom build's native AV1 decoder requires hardware;
the same generated two-frame sample decodes with the old binary and fails with
`Function not implemented` in the initial custom build. Desktop now statically
links dav1d 1.5.4 to preserve software AV1 decoding without adding an encoder.
Mobile build inputs and configuration remain unchanged.

- Source: VideoLAN's official dav1d 1.5.4 archive and adjacent SHA-256 file at
  <https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/>.
- SHA-256: `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5`.
- Reviewed the upstream Meson build: compiler/assembler feature checks and local
  code generation; tests, tools and examples are disabled, and Meson cannot
  download fallback subprojects (`--wrap-mode nodownload`).
- NVD's dav1d query on 2026-10-05 returned CVE-2023-32570 (before 1.2.0) and
  CVE-2024-1580 (through 1.4.0); neither affects 1.5.4. The VideoLAN GitHub mirror
  listed no published advisories. This is an advisory check, not a source audit.
- Meson/Ninja come from Ubuntu, Homebrew and MSYS2's normal package repositories.
  Checked Meson 0.61.2 (Ubuntu 22.04), 1.11.2 (MSYS2), 1.12.1 (Homebrew), and
  locally installed 1.11.1 against OSV's PyPI advisories: no matching advisories.
  Meson and Ninja are build tools and are not shipped in the app.

Windows ARM64 disables incidental bzlib/lzma/iconv autodetection from the build
tool environment, retains explicit zlib support, and uses a separate runtime
runner without MSYS2 before publication. macOS verification rejects load commands
requiring a version newer than 13.3, for both executables and both slices.

## Browser build — 2026-10-06

Emscripten 6.0.11 is installed with the official emsdk at the commit in
`versions.env`. Its release manifest pins the compiler archive; the installer
downloads the toolchain from the Emscripten project's storage. The installer and
the x264/zimg/dav1d build scripts were inspected before execution. The published
GitHub advisory lists for emsdk, Emscripten and ffmpeg.wasm were empty at review.
The media library pins above are reused.

The compiler's zlib port pins 1.3.2 and verifies its source with SHA-512.
CVE-2026-85091 concerns the `gzwrite`/`gzprintf` nonblocking gzip-file APIs.
FFmpeg has no references to these APIs; this build links the static port for
the compression/decompression APIs. This is a call-site assessment, not an
exhaustive security audit or a claim that zlib 1.3.2 has no advisories.

The browser test wrapper is the existing Ente version, `@ffmpeg/ffmpeg` 0.12.15,
with `@ffmpeg/types` 0.12.4. npm metadata points to the upstream ffmpeg.wasm
repository, neither package has install lifecycle scripts, and npm's advisory
query returned no matches for these exact versions. The test installation uses
`--ignore-scripts`; neither package is included in the core artifact.
