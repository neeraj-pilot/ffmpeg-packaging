#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/dict.h"
#include "libavutil/display.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/pixdesc.h"
#include "libavutil/rational.h"

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

void ffmpeg_ffi_init_logging(void);

static void json_string(AVBPrint *out, const char *value)
{
    const unsigned char *p = (const unsigned char *)(value ? value : "");
    const unsigned char *end = p + strlen((const char *)p);

    av_bprint_chars(out, '"', 1);
    for (; *p; p++) {
        if (*p >= 0x80) {
            const unsigned char *start = p;
            int32_t codepoint;
            if (av_utf8_decode(&codepoint, &p, end, 0) < 0)
                av_bprintf(out, "\\ufffd");
            else
                av_bprint_append_data(out, (const char *)start, p - start);
            p--;
            continue;
        }
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
    json_string_field(out, &first, "profile",
                      avcodec_profile_name(codec->codec_id, codec->profile));
    json_string_field(out, &first, "codec_type",
                      av_get_media_type_string(codec->codec_type));
    json_rational_field(out, &first, "r_frame_rate", stream->r_frame_rate);
    json_rational_field(out, &first, "avg_frame_rate", stream->avg_frame_rate);
    json_time_field(out, &first, "duration", stream->duration,
                    stream->time_base);
    json_string_i64_field(out, &first, "bit_rate", codec->bit_rate);
    json_string_i64_field(out, &first, "nb_frames", stream->nb_frames);
    json_rational_field(out, &first, "time_base", stream->time_base);
    json_time_field(out, &first, "start_time", stream->start_time,
                    stream->time_base);

    if (codec->codec_type == AVMEDIA_TYPE_VIDEO) {
        json_int_field(out, &first, "width", codec->width);
        json_int_field(out, &first, "height", codec->height);
        const AVRational sar = av_guess_sample_aspect_ratio(NULL, (AVStream *)stream, NULL);
        if (sar.num > 0 && sar.den > 0) {
            json_comma(out, &first);
            av_bprintf(out, "\"sample_aspect_ratio\":\"%d:%d\"", sar.num, sar.den);
        }
        json_string_field(out, &first, "pix_fmt", av_get_pix_fmt_name(codec->format));
        json_string_field(out, &first, "color_range", av_color_range_name(codec->color_range));
        json_string_field(out, &first, "color_space", av_color_space_name(codec->color_space));
        json_string_field(out, &first, "color_transfer", av_color_transfer_name(codec->color_trc));
        json_string_field(out, &first, "color_primaries", av_color_primaries_name(codec->color_primaries));
        json_int_field(out, &first, "level", codec->level);

        const AVPacketSideData *matrix = av_packet_side_data_get(
            codec->coded_side_data, codec->nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX);
        if (matrix && matrix->size >= 9 * sizeof(int32_t)) {
            const double rotation = av_display_rotation_get((int32_t *)matrix->data);
            if (!isnan(rotation)) {
                json_comma(out, &first);
                av_bprintf(out, "\"side_data_list\":[{\"side_data_type\":\"Display Matrix\","
                                "\"rotation\":%.0f}]", rotation);
            }
        }
    } else if (codec->codec_type == AVMEDIA_TYPE_AUDIO) {
        char layout[128];
        json_string_i64_field(out, &first, "sample_rate", codec->sample_rate);
        json_int_field(out, &first, "channels", codec->ch_layout.nb_channels);
        if (av_channel_layout_describe(&codec->ch_layout, layout, sizeof(layout)) >= 0)
            json_string_field(out, &first, "channel_layout", layout);
    }

    json_comma(out, &first);
    json_key(out, "disposition");
    av_bprint_chars(out, '{', 1);
    int first_disposition = 1;
    for (unsigned int bit = 0; bit < 31; bit++) {
        const int flag = 1U << bit;
        const char *name = av_disposition_to_string(flag);
        if (name)
            json_int_field(out, &first_disposition, name, !!(stream->disposition & flag));
    }
    av_bprint_chars(out, '}', 1);

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
    ffmpeg_ffi_init_logging();

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
