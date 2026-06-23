#include "ffmpeg_ffi.h"

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

#define ARGC(args) ((int)(sizeof(args) / sizeof((args)[0]) - 1))

typedef struct HarnessStats {
    atomic_int callbacks;
    atomic_int callbacks_after_teardown;
    atomic_int accept_callbacks;
    int64_t last_progress_us;
} HarnessStats;

typedef struct ExecuteTask {
    FfmpegFfiSession *session;
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
    FfmpegFfiSession *session;
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
    FfmpegFfiSession *session = ffmpeg_session_new(NULL, NULL);
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
    FfmpegFfiSession *session;
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
    FfmpegFfiSession *long_session;
    FfmpegFfiSession *short_session;
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

int main(void)
{
    char *normal[] = {
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-f", "lavfi",
        "-i", "testsrc2=duration=1:size=160x90:rate=5",
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
    run_command("reentry", ARGC(reentry), reentry, 0);
    run_signal_handler_preserved();
    run_overwrite_state_reset();
    run_cancelled("cancel", ARGC(long_encode), long_encode, 500000);
    run_cancelled("immediate-cancel", ARGC(long_encode), long_encode, 1000);
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
        fprintf(stderr, "ffmpeg_ffi_harness failed: %d failure(s)\n", failures);
        return 1;
    }

    fprintf(stderr, "ffmpeg_ffi_harness passed\n");
    remove("hls-key.bin");
    remove("hls-keyinfo.txt");
    remove("hls-cancel.m3u8");
    remove("hls-cancel.ts");
    return 0;
}
