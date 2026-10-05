#ifndef FFMPEG_RUNTIME_H
#define FFMPEG_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ffmpeg_progress_callback)(void *opaque,
                                         int64_t time_us,
                                         int is_final);

typedef struct FfmpegSession FfmpegSession;

FfmpegSession *ffmpeg_session_new(ffmpeg_progress_callback progress_cb,
                                     void *progress_opaque);

/* Free only after execute returns; no callbacks occur after that return. */
void ffmpeg_session_free(FfmpegSession *session);

/* Borrowed diagnostic bytes; truncation may split UTF-8. Read after execute. */
const char *ffmpeg_session_output(FfmpegSession *session);

/* A session runs once. Cancellation before execution is preserved. */
int ffmpeg_execute(FfmpegSession *session, int argc, char **argv);

void ffmpeg_cancel(FfmpegSession *session);

int ffmpeg_probe_media_json(const char *path, char **json_out);

void ffmpeg_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
