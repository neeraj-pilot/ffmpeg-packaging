#include "ffmpeg_runtime.h"

#include <errno.h>
#include <ctype.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define ARGC(args) ((int)(sizeof(args) / sizeof((args)[0]) - 1))

typedef struct HarnessStats {
    atomic_int callbacks;
    atomic_int callbacks_after_teardown;
    atomic_int accept_callbacks;
    int64_t last_progress_us;
} HarnessStats;

typedef struct ExecuteTask {
    FfmpegSession *session;
    int argc;
    char **argv;
    int ret;
    atomic_int done;
} ExecuteTask;

typedef struct WatchdogTask {
    const char *name;
    atomic_int *done;
    useconds_t timeout_us;
} WatchdogTask;

static int failures;
static volatile sig_atomic_t signal_seen;

static void fail(const char *name, const char *message)
{
    fprintf(stderr, "not ok - %s: %s\n", name, message);
    failures++;
}

static void ok(const char *name)
{
    fprintf(stderr, "ok - %s\n", name);
}

static void harness_signal_handler(int sig)
{
    signal_seen = sig;
}

static const char *skip_json_ws(const char *p)
{
    while (*p && isspace((unsigned char)*p))
        p++;
    return p;
}

static const char *parse_json_value(const char *p);

static const char *parse_json_string(const char *p)
{
    if (*p++ != '"')
        return NULL;

    while (*p) {
        unsigned char c = (unsigned char)*p++;
        if (c == '"')
            return p;
        if (c < 0x20)
            return NULL;
        if (c != '\\')
            continue;

        c = (unsigned char)*p++;
        switch (c) {
        case '"':
        case '\\':
        case '/':
        case 'b':
        case 'f':
        case 'n':
        case 'r':
        case 't':
            break;
        case 'u':
            for (int i = 0; i < 4; i++) {
                if (!isxdigit((unsigned char)p[i]))
                    return NULL;
            }
            p += 4;
            break;
        default:
            return NULL;
        }
    }
    return NULL;
}

static const char *parse_json_number(const char *p)
{
    if (*p == '-')
        p++;
    if (*p == '0') {
        p++;
    } else if (isdigit((unsigned char)*p)) {
        while (isdigit((unsigned char)*p))
            p++;
    } else {
        return NULL;
    }

    if (*p == '.') {
        p++;
        if (!isdigit((unsigned char)*p))
            return NULL;
        while (isdigit((unsigned char)*p))
            p++;
    }

    if (*p == 'e' || *p == 'E') {
        p++;
        if (*p == '+' || *p == '-')
            p++;
        if (!isdigit((unsigned char)*p))
            return NULL;
        while (isdigit((unsigned char)*p))
            p++;
    }
    return p;
}

static const char *parse_json_array(const char *p)
{
    if (*p++ != '[')
        return NULL;
    p = skip_json_ws(p);
    if (*p == ']')
        return p + 1;

    for (;;) {
        p = parse_json_value(p);
        if (!p)
            return NULL;
        p = skip_json_ws(p);
        if (*p == ']')
            return p + 1;
        if (*p++ != ',')
            return NULL;
        p = skip_json_ws(p);
    }
}

static const char *parse_json_object(const char *p)
{
    if (*p++ != '{')
        return NULL;
    p = skip_json_ws(p);
    if (*p == '}')
        return p + 1;

    for (;;) {
        p = parse_json_string(p);
        if (!p)
            return NULL;
        p = skip_json_ws(p);
        if (*p++ != ':')
            return NULL;
        p = skip_json_ws(p);
        p = parse_json_value(p);
        if (!p)
            return NULL;
        p = skip_json_ws(p);
        if (*p == '}')
            return p + 1;
        if (*p++ != ',')
            return NULL;
        p = skip_json_ws(p);
    }
}

static const char *parse_json_literal(const char *p, const char *literal)
{
    size_t len = strlen(literal);
    return strncmp(p, literal, len) == 0 ? p + len : NULL;
}

static const char *parse_json_value(const char *p)
{
    p = skip_json_ws(p);
    switch (*p) {
    case '{':
        return parse_json_object(p);
    case '[':
        return parse_json_array(p);
    case '"':
        return parse_json_string(p);
    case 't':
        return parse_json_literal(p, "true");
    case 'f':
        return parse_json_literal(p, "false");
    case 'n':
        return parse_json_literal(p, "null");
    default:
        return parse_json_number(p);
    }
}

static int json_is_valid(const char *json)
{
    const char *end;

    if (!json)
        return 0;
    end = parse_json_value(json);
    return end && *skip_json_ws(end) == '\0';
}

static void progress_cb(void *opaque, int64_t time_us, int is_final)
{
    HarnessStats *stats = opaque;

    (void)is_final;
    atomic_fetch_add(&stats->callbacks, 1);
    if (!atomic_load(&stats->accept_callbacks))
        atomic_fetch_add(&stats->callbacks_after_teardown, 1);
    stats->last_progress_us = time_us;
}

static void stats_init(HarnessStats *stats)
{
    atomic_init(&stats->callbacks, 0);
    atomic_init(&stats->callbacks_after_teardown, 0);
    atomic_init(&stats->accept_callbacks, 1);
    stats->last_progress_us = -1;
}

static void *execute_thread(void *opaque)
{
    ExecuteTask *task = opaque;

    task->ret = ffmpeg_execute(task->session, task->argc, task->argv);
    atomic_store(&task->done, 1);
    return NULL;
}

static void *watchdog_thread(void *opaque)
{
    WatchdogTask *task = opaque;
    const useconds_t step_us = 50000;
    useconds_t elapsed_us = 0;

    while (elapsed_us < task->timeout_us) {
        if (atomic_load(task->done))
            return NULL;
        usleep(step_us);
        elapsed_us += step_us;
    }

    if (!atomic_load(task->done)) {
        fprintf(stderr, "not ok - %s: cancellation timed out\n", task->name);
        _exit(124);
    }
    return NULL;
}

static int run_command(const char *name, int argc, char **argv, int expected)
{
    HarnessStats stats;
    FfmpegSession *session;
    int ret;

    stats_init(&stats);
    session = ffmpeg_session_new(progress_cb, &stats);
    if (!session) {
        fail(name, "session allocation failed");
        return -1;
    }

    ret = ffmpeg_execute(session, argc, argv);
    atomic_store(&stats.accept_callbacks, 0);
    usleep(200000);

    if (ret != expected) {
        fprintf(stderr, "%s returned %d, expected %d\n", name, ret, expected);
        fail(name, "unexpected return code");
    } else if (atomic_load(&stats.callbacks_after_teardown) != 0) {
        fail(name, "progress callback after callback teardown");
    } else {
        ok(name);
    }

    ffmpeg_session_free(session);
    return ret;
}

static int execute_command_no_check(int argc, char **argv)
{
    FfmpegSession *session = ffmpeg_session_new(NULL, NULL);
    int ret;

    if (!session)
        return -1;
    ret = ffmpeg_execute(session, argc, argv);
    ffmpeg_session_free(session);
    return ret;
}

static int file_equals_string(const char *path, const char *expected)
{
    FILE *file = fopen(path, "rb");
    size_t expected_len = strlen(expected);
    char buffer[64];
    size_t read_len;
    int extra;

    if (!file)
        return 0;
    read_len = fread(buffer, 1, sizeof(buffer), file);
    extra = fgetc(file);
    fclose(file);

    return read_len == expected_len &&
           extra == EOF &&
           memcmp(buffer, expected, expected_len) == 0;
}

static int write_file(const char *path, const void *data, size_t len)
{
    FILE *file = fopen(path, "wb");

    if (!file)
        return -1;
    if (fwrite(data, 1, len, file) != len) {
        fclose(file);
        return -1;
    }
    return fclose(file);
}

static void run_signal_handler_preserved(void)
{
    struct sigaction custom_action;
    struct sigaction previous_term_action;
    struct sigaction after_term_action;
#ifdef SIGPIPE
    struct sigaction previous_pipe_action;
    struct sigaction after_pipe_action;
#endif
    char *argv[] = {
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=0.1:size=16x16:rate=1",
        "-frames:v", "1",
        "-f", "null",
        "-",
        NULL,
    };

    memset(&custom_action, 0, sizeof(custom_action));
    custom_action.sa_handler = harness_signal_handler;
    sigemptyset(&custom_action.sa_mask);
    signal_seen = 0;

    if (sigaction(SIGTERM, &custom_action, &previous_term_action) != 0) {
        fail("signal-handler-preserved", "failed to install SIGTERM handler");
        return;
    }
#ifdef SIGPIPE
    if (sigaction(SIGPIPE, &custom_action, &previous_pipe_action) != 0) {
        sigaction(SIGTERM, &previous_term_action, NULL);
        fail("signal-handler-preserved", "failed to install SIGPIPE handler");
        return;
    }
#endif

    run_command("signal-handler-command", ARGC(argv), argv, 0);

    if (sigaction(SIGTERM, NULL, &after_term_action) != 0) {
        sigaction(SIGTERM, &previous_term_action, NULL);
#ifdef SIGPIPE
        sigaction(SIGPIPE, &previous_pipe_action, NULL);
#endif
        fail("signal-handler-preserved", "failed to inspect SIGTERM handler");
        return;
    }
    if (after_term_action.sa_handler != harness_signal_handler) {
        sigaction(SIGTERM, &previous_term_action, NULL);
#ifdef SIGPIPE
        sigaction(SIGPIPE, &previous_pipe_action, NULL);
#endif
        fail("signal-handler-preserved", "ffmpeg_execute replaced SIGTERM handler");
        return;
    }

#ifdef SIGPIPE
    if (sigaction(SIGPIPE, NULL, &after_pipe_action) != 0) {
        sigaction(SIGTERM, &previous_term_action, NULL);
        sigaction(SIGPIPE, &previous_pipe_action, NULL);
        fail("sigpipe-handler-preserved", "failed to inspect SIGPIPE handler");
        return;
    }
    if (after_pipe_action.sa_handler != harness_signal_handler) {
        sigaction(SIGTERM, &previous_term_action, NULL);
        sigaction(SIGPIPE, &previous_pipe_action, NULL);
        fail("sigpipe-handler-preserved", "ffmpeg_execute replaced SIGPIPE handler");
        return;
    }
#endif

    sigaction(SIGTERM, &previous_term_action, NULL);
#ifdef SIGPIPE
    sigaction(SIGPIPE, &previous_pipe_action, NULL);
    ok("sigpipe-handler-preserved");
#endif
    ok("signal-handler-preserved");
}

static void run_overwrite_state_reset(void)
{
    char victim[] = "overwrite-victim.mp4";
    const char *sentinel = "sentinel";
    char *seed[] = {
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=0.1:size=16x16:rate=1",
        "-frames:v", "1",
        "-f", "null",
        "-",
        NULL,
    };
    char *second[] = {
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-f", "lavfi",
        "-i", "testsrc2=duration=0.1:size=16x16:rate=1",
        "-frames:v", "1",
        victim,
        NULL,
    };
    FILE *file;

    remove(victim);
    run_command("overwrite-state-seed", ARGC(seed), seed, 0);

    file = fopen(victim, "wb");
    if (!file) {
        fail("overwrite-state-reset", "failed to create sentinel output");
        return;
    }
    fputs(sentinel, file);
    fclose(file);

    /*
     * FFmpeg maps this no-overwrite AVERROR_EXIT path to return code 0.
     * The regression oracle is that the existing file remains untouched.
     */
    execute_command_no_check(ARGC(second), second);

    if (!file_equals_string(victim, sentinel))
        fail("overwrite-state-reset", "prior -y leaked into later command");
    else
        ok("overwrite-state-reset");

    remove(victim);
}

static int run_cancelled(const char *name, int argc, char **argv,
                         useconds_t cancel_after_us)
{
    HarnessStats stats;
    FfmpegSession *session;
    ExecuteTask task;
    pthread_t thread;
    pthread_t watchdog;
    WatchdogTask watchdog_task;

    stats_init(&stats);
    session = ffmpeg_session_new(progress_cb, &stats);
    if (!session) {
        fail(name, "session allocation failed");
        return -1;
    }

    task.session = session;
    task.argc = argc;
    task.argv = argv;
    task.ret = -9999;
    atomic_init(&task.done, 0);
    watchdog_task.name = name;
    watchdog_task.done = &task.done;
    watchdog_task.timeout_us = 15000000;

    if (pthread_create(&thread, NULL, execute_thread, &task) != 0) {
        ffmpeg_session_free(session);
        fail(name, "pthread_create failed");
        return -1;
    }
    if (pthread_create(&watchdog, NULL, watchdog_thread, &watchdog_task) != 0) {
        ffmpeg_cancel(session);
        pthread_join(thread, NULL);
        ffmpeg_session_free(session);
        fail(name, "watchdog pthread_create failed");
        return -1;
    }

    usleep(cancel_after_us);
    ffmpeg_cancel(session);
    atomic_store(&stats.accept_callbacks, 0);
    pthread_join(thread, NULL);
    pthread_join(watchdog, NULL);
    usleep(200000);

    if (task.ret != 255) {
        fprintf(stderr, "%s returned %d, expected 255\n", name, task.ret);
        fail(name, "unexpected cancel return code");
    } else if (atomic_load(&stats.callbacks_after_teardown) != 0) {
        fail(name, "progress callback after callback teardown");
    } else {
        ok(name);
    }

    ffmpeg_session_free(session);
    return task.ret;
}

static void run_overlap(int argc, char **long_argv, int short_argc,
                        char **short_argv)
{
    HarnessStats stats;
    FfmpegSession *long_session;
    FfmpegSession *short_session;
    ExecuteTask task;
    pthread_t thread;
    int ret;

    stats_init(&stats);
    long_session = ffmpeg_session_new(progress_cb, &stats);
    short_session = ffmpeg_session_new(NULL, NULL);
    if (!long_session || !short_session) {
        fail("overlap", "session allocation failed");
        ffmpeg_session_free(long_session);
        ffmpeg_session_free(short_session);
        return;
    }

    task.session = long_session;
    task.argc = argc;
    task.argv = long_argv;
    task.ret = -9999;
    atomic_init(&task.done, 0);

    if (pthread_create(&thread, NULL, execute_thread, &task) != 0) {
        fail("overlap", "pthread_create failed");
        ffmpeg_session_free(long_session);
        ffmpeg_session_free(short_session);
        return;
    }

    usleep(250000);
    ret = ffmpeg_execute(short_session, short_argc, short_argv);
    ffmpeg_cancel(long_session);
    atomic_store(&stats.accept_callbacks, 0);
    pthread_join(thread, NULL);

    if (ret == -EBUSY)
        ok("overlap");
    else {
        fprintf(stderr, "overlap returned %d, expected %d\n", ret, -EBUSY);
        fail("overlap", "unexpected return code");
    }

    ffmpeg_session_free(long_session);
    ffmpeg_session_free(short_session);
}

static void run_probe(const char *path)
{
    char *json = NULL;
    int ret = ffmpeg_probe_media_json(path, &json);

    if (ret != 0 || !json) {
        fprintf(stderr, "probe returned %d\n", ret);
        fail("probe", "probe failed");
    } else if (!json_is_valid(json)) {
        fail("probe", "invalid JSON");
    } else if (!strstr(json, "\"format\":{") || !strstr(json, "\"streams\":[")) {
        fail("probe", "missing expected ffprobe-compatible fields");
    } else {
        ok("probe");
    }
    ffmpeg_free_string(json);
}

static void run_pre_cancelled(int argc, char **argv)
{
    FfmpegSession *session = ffmpeg_session_new(NULL, NULL);
    ffmpeg_cancel(session);
    const int ret = ffmpeg_execute(session, argc, argv);
    if (ret == 255 && access("overlap.mp4", F_OK) != 0)
        ok("cancel-before-execute");
    else
        fail("cancel-before-execute", "started a cancelled command");
    ffmpeg_session_free(session);
}

static void run_stalled_io(int output)
{
    const char *name = output ? "stalled-output-cancel" : "stalled-input-cancel";
    struct sockaddr_in address = { .sin_family = AF_INET,
                                   .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t address_size = sizeof(address);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, address_size) ||
        listen(listener, 1) ||
        getsockname(listener, (struct sockaddr *)&address, &address_size)) {
        fail(name, "could not create loopback peer");
        if (listener >= 0) close(listener);
        return;
    }

    // The listening peer never consumes or supplies media. Its small receive
    // buffer makes raw-video output block in a write; input blocks while probing.
    int receive_buffer = 1024;
    setsockopt(listener, SOL_SOCKET, SO_RCVBUF, &receive_buffer, sizeof(receive_buffer));
    char url[128];
    snprintf(url, sizeof(url), "tcp://127.0.0.1:%d", ntohs(address.sin_port));
    char *input_argv[] = {
        "ffmpeg", "-nostdin", "-f", "mpegts", "-i", url,
        "-f", "null", "-", NULL,
    };
    char *output_argv[] = {
        "ffmpeg", "-nostdin", "-f", "lavfi", "-i",
        "testsrc2=size=1280x720:rate=30", "-c:v", "rawvideo",
        "-f", "rawvideo", url, NULL,
    };
    if (output)
        run_cancelled(name, ARGC(output_argv), output_argv, 1000000);
    else
        run_cancelled(name, ARGC(input_argv), input_argv, 1000000);
    close(listener);
}

static void run_diagnostics(void)
{
    char *quiet[] = {
        "ffmpeg", "-loglevel", "quiet", "-i", "normal.mp4",
        "-frames:v", "1", "-f", "null", "-", NULL,
    };
    run_command("quiet-command", ARGC(quiet), quiet, 0);
    char *argv[] = { "ffmpeg", "-ente_nonexistent_option", NULL };
    FfmpegSession *session = ffmpeg_session_new(NULL, NULL);
    const int ret = ffmpeg_execute(session, ARGC(argv), argv);
    const char *output = ffmpeg_session_output(session);
    if (ret != 0 && strstr(output, "ente_nonexistent_option") && strlen(output) < 8192)
        ok("diagnostics");
    else
        fail("diagnostics", "missing bounded command diagnostics");
    ffmpeg_session_free(session);
}

static void run_metadata_probe(void)
{
    const char *chapters = ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening\n";
    if (write_file("chapters.txt", chapters, strlen(chapters))) {
        fail("metadata-fixture", "could not write chapters");
        return;
    }
    char *argv[] = {
        "ffmpeg", "-y", "-display_rotation", "90", "-i", "normal.mp4",
        "-f", "ffmetadata", "-i", "chapters.txt", "-map_chapters", "1",
        "-c", "copy", "-metadata", "comment=caf\xe9",
        "-timecode", "12:34:56:00", "rotated.mp4", NULL,
    };
    const char *fields[] = {
        "\"color_transfer\":\"smpte2084\"",
        "\"sample_aspect_ratio\":\"4:3\"",
        "\"side_data_type\":\"Display Matrix\"",
        "\"rotation\":",
        "\"pix_fmt\":\"yuv420p\"",
        "\"disposition\":",
        "\"comment\":\"caf\\ufffd\"",
        "\"codec_long_name\":\"H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10\"",
        "\"codec_tag_string\":\"avc1\"",
        "\"codec_tag_string\":\"tmcd\"",
        "\"display_aspect_ratio\":\"64:27\"",
        "\"field_order\":\"progressive\"",
        "\"bits_per_raw_sample\":\"8\"",
        "\"coded_width\":160",
        "\"coded_height\":90",
        "\"is_avc\":\"true\"",
        "\"duration_ts\":",
        "\"title\":\"Opening\"",
        "\"chapters\":[{",
        "\"end_time\":\"1.000000\"",
    };
    char *json = NULL;
    run_command("metadata-fixture", ARGC(argv), argv, 0);
    const int ret = ffmpeg_probe_media_json("rotated.mp4", &json);
    if (ret || !json) {
        fail("metadata-probe", "probe failed");
    } else {
        if (strstr(json, "\"codec_name\":\"none\""))
            fail("metadata-probe", "unknown timecode codec should be omitted");
        for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
            if (!strstr(json, fields[i])) {
                fail("metadata-probe", fields[i]);
                fprintf(stderr, "%s\n", json);
            }
        }
        if (json_is_valid(json))
            ok("metadata-probe-json");
        else
            fail("metadata-probe-json", "invalid JSON");
    }
    ffmpeg_free_string(json);
    remove("rotated.mp4");
    remove("chapters.txt");
}

static void run_audio_metadata_probe(void)
{
    char *argv[] = {
        "ffmpeg", "-y", "-f", "lavfi", "-i", "sine=duration=1:sample_rate=48000",
        "-c:a", "pcm_s24le", "audio.wav", NULL,
    };
    char *json = NULL;
    run_command("audio-metadata-fixture", ARGC(argv), argv, 0);
    const int ret = ffmpeg_probe_media_json("audio.wav", &json);
    if (!ret && json && json_is_valid(json) &&
        strstr(json, "\"sample_fmt\":\"s32\"") &&
        strstr(json, "\"bits_per_sample\":24") &&
        strstr(json, "\"bits_per_raw_sample\":\"24\"") &&
        strstr(json, "\"sample_rate\":\"48000\""))
        ok("audio-metadata-probe");
    else
        fail("audio-metadata-probe", "missing PCM format or bit depth");
    ffmpeg_free_string(json);
    remove("audio.wav");
}

int main(void)
{
    char *normal[] = {
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=1:size=160x90:rate=5",
        "-vf", "setsar=4/3,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
        "-color_trc", "smpte2084",
        "-color_primaries", "bt2020",
        "-colorspace", "bt2020nc",
        "-an",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-f", "mp4",
        "normal.mp4",
        NULL,
    };
    char *reentry[] = {
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=1:size=160x90:rate=5",
        "-an",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-f", "mp4",
        "reentry.mp4",
        NULL,
    };
    char *long_encode[] = {
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=60:size=1280x720:rate=30",
        "-an",
        "-c:v", "libx264",
        "-preset", "medium",
        "-f", "mp4",
        "cancel.mp4",
        NULL,
    };
    char *short_encode[] = {
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=1:size=96x96:rate=2",
        "-an",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-f", "mp4",
        "overlap.mp4",
        NULL,
    };
    char *hls_aes_cancel[] = {
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=60:size=1280x720:rate=30",
        "-an",
        "-c:v", "libx264",
        "-preset", "medium",
        "-f", "hls",
        "-hls_time", "1",
        "-hls_flags", "single_file",
        "-hls_list_size", "0",
        "-hls_key_info_file", "hls-keyinfo.txt",
        "hls-cancel.m3u8",
        NULL,
    };
    const unsigned char hls_key[16] = "0123456789abcdef";
    const char *hls_keyinfo =
        "hls-key.bin\n"
        "hls-key.bin\n"
        "0123456789abcdeffedcba9876543210\n";

    remove("normal.mp4");
    remove("reentry.mp4");
    remove("cancel.mp4");
    remove("overlap.mp4");
    remove("overwrite-victim.mp4");
    remove("hls-key.bin");
    remove("hls-keyinfo.txt");
    remove("hls-cancel.m3u8");
    remove("hls-cancel.ts");

    run_command("success", ARGC(normal), normal, 0);
    run_pre_cancelled(ARGC(short_encode), short_encode);
    run_diagnostics();
    run_metadata_probe();
    run_audio_metadata_probe();
    run_command("reentry", ARGC(reentry), reentry, 0);
    run_signal_handler_preserved();
    run_overwrite_state_reset();
    run_cancelled("cancel", ARGC(long_encode), long_encode, 500000);
    run_cancelled("immediate-cancel", ARGC(long_encode), long_encode, 1000);
    run_stalled_io(0);
    run_stalled_io(1);
    if (write_file("hls-key.bin", hls_key, sizeof(hls_key)) != 0 ||
        write_file("hls-keyinfo.txt", hls_keyinfo, strlen(hls_keyinfo)) != 0) {
        fail("hls-aes-cancel", "failed to create HLS key fixtures");
    } else {
        run_cancelled("hls-aes-cancel", ARGC(hls_aes_cancel), hls_aes_cancel,
                      500000);
        run_command("post-hls-cancel-reentry", ARGC(reentry), reentry, 0);
    }
    run_overlap(ARGC(long_encode), long_encode, ARGC(short_encode), short_encode);
    run_probe("normal.mp4");
    run_probe("reentry.mp4");

    if (failures) {
        fprintf(stderr, "ffmpeg_runtime_harness failed: %d failure(s)\n", failures);
        return 1;
    }

    fprintf(stderr, "ffmpeg_runtime_harness passed\n");
    remove("hls-key.bin");
    remove("hls-keyinfo.txt");
    remove("hls-cancel.m3u8");
    remove("hls-cancel.ts");
    return 0;
}
