#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/rational.h"

#include <inttypes.h>
#include <stdint.h>

static void json_string(AVBPrint *out, const char *value)
{
    const unsigned char *p = (const unsigned char *)(value ? value : "");

    av_bprint_chars(out, '"', 1);
    for (; *p; p++) {
        switch (*p) {
        case '"':
            av_bprintf(out, "\\\"");
            break;
        case '\\':
            av_bprintf(out, "\\\\");
            break;
        case '\b':
            av_bprintf(out, "\\b");
            break;
        case '\f':
            av_bprintf(out, "\\f");
            break;
        case '\n':
            av_bprintf(out, "\\n");
            break;
        case '\r':
            av_bprintf(out, "\\r");
            break;
        case '\t':
            av_bprintf(out, "\\t");
            break;
        default:
            if (*p < 0x20)
                av_bprintf(out, "\\u%04x", *p);
            else
                av_bprint_chars(out, (char)*p, 1);
        }
    }
    av_bprint_chars(out, '"', 1);
}

static void json_key(AVBPrint *out, const char *key)
{
    json_string(out, key);
    av_bprint_chars(out, ':', 1);
}

static void json_comma(AVBPrint *out, int *first)
{
    if (*first)
        *first = 0;
    else
        av_bprint_chars(out, ',', 1);
}

static void json_string_field(AVBPrint *out, int *first,
                              const char *key, const char *value)
{
    if (!value)
        return;
    json_comma(out, first);
    json_key(out, key);
    json_string(out, value);
}

static void json_int_field(AVBPrint *out, int *first,
                           const char *key, int64_t value)
{
    json_comma(out, first);
    json_key(out, key);
    av_bprintf(out, "%" PRId64, value);
}

static void json_string_i64_field(AVBPrint *out, int *first,
                                  const char *key, int64_t value)
{
    if (value < 0)
        return;
    json_comma(out, first);
    json_key(out, key);
    av_bprintf(out, "\"%" PRId64 "\"", value);
}

static void json_time_field(AVBPrint *out, int *first,
                            const char *key, int64_t value, AVRational base)
{
    if (value == AV_NOPTS_VALUE || value < 0)
        return;
    json_comma(out, first);
    json_key(out, key);
    av_bprintf(out, "\"%.6f\"", value * av_q2d(base));
}

static void json_rational_field(AVBPrint *out, int *first,
                                const char *key, AVRational value)
{
    if (!value.num || !value.den)
        return;
    json_comma(out, first);
    json_key(out, key);
    av_bprintf(out, "\"%d/%d\"", value.num, value.den);
}

static void json_metadata(AVBPrint *out, AVDictionary *metadata)
{
    const AVDictionaryEntry *entry = NULL;
    int first = 1;

    av_bprint_chars(out, '{', 1);
    while ((entry = av_dict_iterate(metadata, entry))) {
        json_comma(out, &first);
        json_key(out, entry->key);
        json_string(out, entry->value);
    }
    av_bprint_chars(out, '}', 1);
}

static void json_stream(AVBPrint *out, const AVStream *stream)
{
    const AVCodecParameters *codec = stream->codecpar;
    const char *codec_name = avcodec_get_name(codec->codec_id);
    int first = 1;

    av_bprint_chars(out, '{', 1);
    json_int_field(out, &first, "index", stream->index);
    json_string_field(out, &first, "codec_name", codec_name);
    json_string_field(out, &first, "codec_type",
                      av_get_media_type_string(codec->codec_type));
    json_rational_field(out, &first, "r_frame_rate", stream->r_frame_rate);
    json_rational_field(out, &first, "avg_frame_rate", stream->avg_frame_rate);
    json_time_field(out, &first, "duration", stream->duration,
                    stream->time_base);
    json_string_i64_field(out, &first, "bit_rate", codec->bit_rate);

    if (codec->codec_type == AVMEDIA_TYPE_VIDEO) {
        json_int_field(out, &first, "width", codec->width);
        json_int_field(out, &first, "height", codec->height);
    } else if (codec->codec_type == AVMEDIA_TYPE_AUDIO) {
        json_string_i64_field(out, &first, "sample_rate", codec->sample_rate);
        json_int_field(out, &first, "channels", codec->ch_layout.nb_channels);
    }

    if (stream->metadata) {
        json_comma(out, &first);
        json_key(out, "tags");
        json_metadata(out, stream->metadata);
    }
    av_bprint_chars(out, '}', 1);
}

int ffmpeg_probe_media_json(const char *path, char **json_out)
{
    AVFormatContext *format = NULL;
    AVBPrint out;
    int ret;

    if (!path || !json_out)
        return AVERROR(EINVAL);
    *json_out = NULL;

    ret = avformat_open_input(&format, path, NULL, NULL);
    if (ret < 0)
        return ret;

    ret = avformat_find_stream_info(format, NULL);
    if (ret < 0)
        goto finish;

    av_bprint_init(&out, 0, AV_BPRINT_SIZE_UNLIMITED);
    av_bprintf(&out, "{\"format\":{");

    int first_format = 1;
    json_string_field(&out, &first_format, "filename", format->url);
    json_int_field(&out, &first_format, "nb_streams", format->nb_streams);
    if (format->iformat)
        json_string_field(&out, &first_format, "format_name",
                          format->iformat->name);
    json_time_field(&out, &first_format, "duration", format->duration,
                    (AVRational){1, AV_TIME_BASE});
    json_string_i64_field(&out, &first_format, "bit_rate", format->bit_rate);
    if (format->metadata) {
        json_comma(&out, &first_format);
        json_key(&out, "tags");
        json_metadata(&out, format->metadata);
    }

    av_bprintf(&out, "},\"streams\":[");
    for (unsigned int i = 0; i < format->nb_streams; i++) {
        if (i)
            av_bprint_chars(&out, ',', 1);
        json_stream(&out, format->streams[i]);
    }
    av_bprintf(&out, "]}");

    ret = av_bprint_finalize(&out, json_out);

finish:
    avformat_close_input(&format);
    return ret;
}

void ffmpeg_free_string(char *value)
{
    av_free(value);
}
