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
