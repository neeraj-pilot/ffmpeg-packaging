#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/dict.h"
#include "libavutil/display.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/rational.h"
#include "libavutil/samplefmt.h"

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

void ffmpeg_runtime_init_logging(void);

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
    if (value == AV_NOPTS_VALUE)
        return;
    json_comma(out, first);
    json_key(out, key);
    av_bprintf(out, "\"%.6f\"", value * av_q2d(base));
}

static void json_rational_field(AVBPrint *out, int *first,
                                const char *key, AVRational value)
{
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

static void json_private_fields(AVBPrint *out, int *first, void *data)
{
    const AVOption *option = NULL;
    while ((option = av_opt_next(data, option))) {
        uint8_t *value;
        if ((option->flags & AV_OPT_FLAG_EXPORT) &&
            av_opt_get(data, option->name, 0, &value) >= 0) {
            json_string_field(out, first, option->name, (char *)value);
            av_free(value);
        }
    }
}

static int json_stream(AVBPrint *out, AVFormatContext *format, AVStream *stream)
{
    const AVCodecParameters *codec = stream->codecpar;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(codec->codec_id);
    const AVCodec *decoder = avcodec_find_decoder(codec->codec_id);
    AVCodecContext *context = NULL;
    int first = 1;
    char value[128];

    // FFprobe opens a decoder for coded dimensions and exported codec properties.
    // Unsupported decoders must not discard metadata already read by libavformat.
    if (decoder) {
        context = avcodec_alloc_context3(decoder);
        if (!context)
            return AVERROR(ENOMEM);
        int ret = avcodec_parameters_to_context(context, codec);
        if (ret < 0) {
            avcodec_free_context(&context);
            return ret;
        }
        context->pkt_timebase = stream->time_base;
        context->thread_count = 1;
        if (avcodec_open2(context, decoder, NULL) < 0)
            avcodec_free_context(&context);
    }

    av_bprint_chars(out, '{', 1);
    json_int_field(out, &first, "index", stream->index);
    if (descriptor) {
        json_string_field(out, &first, "codec_name", descriptor->name);
        json_string_field(out, &first, "codec_long_name", descriptor->long_name);
    }
    json_string_field(out, &first, "codec_tag_string", av_fourcc2str(codec->codec_tag));
    snprintf(value, sizeof(value), "0x%04" PRIx32, codec->codec_tag);
    json_string_field(out, &first, "codec_tag", value);
    AVBPrint mime;
    av_bprint_init(&mime, 0, AV_BPRINT_SIZE_UNLIMITED);
    if (av_mime_codec_str(codec, stream->avg_frame_rate, &mime) == 0)
        json_string_field(out, &first, "mime_codec_string", mime.str);
    av_bprint_finalize(&mime, NULL);
    const char *profile = avcodec_profile_name(codec->codec_id, codec->profile);
    if (!profile && codec->profile != AV_PROFILE_UNKNOWN) {
        snprintf(value, sizeof(value), "%d", codec->profile);
        profile = value;
    }
    json_string_field(out, &first, "profile", profile);
    json_string_field(out, &first, "codec_type",
                      av_get_media_type_string(codec->codec_type));
    json_rational_field(out, &first, "r_frame_rate", stream->r_frame_rate);
    json_rational_field(out, &first, "avg_frame_rate", stream->avg_frame_rate);
    json_time_field(out, &first, "duration", stream->duration,
                    stream->time_base);
    if (codec->bit_rate > 0)
        json_string_i64_field(out, &first, "bit_rate", codec->bit_rate);
    if (stream->nb_frames > 0)
        json_string_i64_field(out, &first, "nb_frames", stream->nb_frames);
    if (stream->start_time != AV_NOPTS_VALUE)
        json_int_field(out, &first, "start_pts", stream->start_time);
    if (stream->duration != AV_NOPTS_VALUE)
        json_int_field(out, &first, "duration_ts", stream->duration);
    if (format->iformat->flags & AVFMT_SHOW_IDS) {
        snprintf(value, sizeof(value), "0x%x", stream->id);
        json_string_field(out, &first, "id", value);
    }
    if (context && context->rc_max_rate > 0)
        json_string_i64_field(out, &first, "max_bit_rate", context->rc_max_rate);
    if (context && context->bits_per_raw_sample > 0)
        json_string_i64_field(out, &first, "bits_per_raw_sample", context->bits_per_raw_sample);
    if (codec->extradata_size > 0)
        json_int_field(out, &first, "extradata_size", codec->extradata_size);
    json_rational_field(out, &first, "time_base", stream->time_base);
    json_time_field(out, &first, "start_time", stream->start_time,
                    stream->time_base);

    if (codec->codec_type == AVMEDIA_TYPE_VIDEO) {
        json_int_field(out, &first, "width", codec->width);
        json_int_field(out, &first, "height", codec->height);
        if (context) {
            json_int_field(out, &first, "coded_width", context->coded_width);
            json_int_field(out, &first, "coded_height", context->coded_height);
        }
        json_int_field(out, &first, "has_b_frames", codec->video_delay);
        const AVRational sar = av_guess_sample_aspect_ratio(format, stream, NULL);
        if (sar.num > 0 && sar.den > 0) {
            json_comma(out, &first);
            av_bprintf(out, "\"sample_aspect_ratio\":\"%d:%d\"", sar.num, sar.den);
            AVRational dar;
            av_reduce(&dar.num, &dar.den, (int64_t)codec->width * sar.num,
                      (int64_t)codec->height * sar.den, 1024 * 1024);
            json_comma(out, &first);
            av_bprintf(out, "\"display_aspect_ratio\":\"%d:%d\"", dar.num, dar.den);
        }
        json_string_field(out, &first, "pix_fmt", av_get_pix_fmt_name(codec->format));
        if (codec->color_range != AVCOL_RANGE_UNSPECIFIED)
            json_string_field(out, &first, "color_range", av_color_range_name(codec->color_range));
        if (codec->color_space != AVCOL_SPC_UNSPECIFIED)
            json_string_field(out, &first, "color_space", av_color_space_name(codec->color_space));
        if (codec->color_trc != AVCOL_TRC_UNSPECIFIED)
            json_string_field(out, &first, "color_transfer", av_color_transfer_name(codec->color_trc));
        if (codec->color_primaries != AVCOL_PRI_UNSPECIFIED)
            json_string_field(out, &first, "color_primaries", av_color_primaries_name(codec->color_primaries));
        json_int_field(out, &first, "level", codec->level);
        if (codec->chroma_location != AVCHROMA_LOC_UNSPECIFIED)
            json_string_field(out, &first, "chroma_location", av_chroma_location_name(codec->chroma_location));
        const char *field_order = NULL;
        switch (codec->field_order) {
        case AV_FIELD_PROGRESSIVE: field_order = "progressive"; break;
        case AV_FIELD_TT: field_order = "tt"; break;
        case AV_FIELD_BB: field_order = "bb"; break;
        case AV_FIELD_TB: field_order = "tb"; break;
        case AV_FIELD_BT: field_order = "bt"; break;
        default: break;
        }
        json_string_field(out, &first, "field_order", field_order);

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
        json_string_field(out, &first, "sample_fmt", av_get_sample_fmt_name(codec->format));
        json_int_field(out, &first, "bits_per_sample", av_get_bits_per_sample(codec->codec_id));
        json_int_field(out, &first, "initial_padding", codec->initial_padding);
        json_string_i64_field(out, &first, "sample_rate", codec->sample_rate);
        json_int_field(out, &first, "channels", codec->ch_layout.nb_channels);
        if (codec->ch_layout.order != AV_CHANNEL_ORDER_UNSPEC &&
            av_channel_layout_describe(&codec->ch_layout, layout, sizeof(layout)) >= 0)
            json_string_field(out, &first, "channel_layout", layout);
    } else if (codec->codec_type == AVMEDIA_TYPE_SUBTITLE) {
        if (codec->width)
            json_int_field(out, &first, "width", codec->width);
        if (codec->height)
            json_int_field(out, &first, "height", codec->height);
    }

    if (context && context->codec->priv_class)
        json_private_fields(out, &first, context->priv_data);
    if (format->iformat->priv_class)
        json_private_fields(out, &first, format->priv_data);

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
    avcodec_free_context(&context);
    return 0;
}

int ffmpeg_probe_media_json(const char *path, char **json_out)
{
    AVFormatContext *format = NULL;
    AVBPrint out;
    int ret;

    if (!path || !json_out)
        return AVERROR(EINVAL);
    *json_out = NULL;
    ffmpeg_runtime_init_logging();

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
    json_int_field(&out, &first_format, "nb_programs", format->nb_programs);
    json_int_field(&out, &first_format, "nb_stream_groups", format->nb_stream_groups);
    json_string_field(&out, &first_format, "format_long_name", format->iformat->long_name);
    json_time_field(&out, &first_format, "start_time", format->start_time,
                    (AVRational){1, AV_TIME_BASE});
    if (format->pb)
        json_string_i64_field(&out, &first_format, "size", avio_size(format->pb));
    json_int_field(&out, &first_format, "probe_score", format->probe_score);
    if (format->iformat)
        json_string_field(&out, &first_format, "format_name",
                          format->iformat->name);
    json_time_field(&out, &first_format, "duration", format->duration,
                    (AVRational){1, AV_TIME_BASE});
    if (format->bit_rate > 0)
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
        ret = json_stream(&out, format, format->streams[i]);
        if (ret < 0) {
            av_bprint_finalize(&out, NULL);
            goto finish;
        }
    }
    av_bprintf(&out, "],\"chapters\":[");
    for (unsigned int i = 0; i < format->nb_chapters; i++) {
        const AVChapter *chapter = format->chapters[i];
        int first_chapter = 1;
        if (i)
            av_bprint_chars(&out, ',', 1);
        av_bprint_chars(&out, '{', 1);
        json_int_field(&out, &first_chapter, "id", chapter->id);
        json_rational_field(&out, &first_chapter, "time_base", chapter->time_base);
        json_int_field(&out, &first_chapter, "start", chapter->start);
        json_time_field(&out, &first_chapter, "start_time", chapter->start, chapter->time_base);
        json_int_field(&out, &first_chapter, "end", chapter->end);
        json_time_field(&out, &first_chapter, "end_time", chapter->end, chapter->time_base);
        if (chapter->metadata) {
            json_comma(&out, &first_chapter);
            json_key(&out, "tags");
            json_metadata(&out, chapter->metadata);
        }
        av_bprint_chars(&out, '}', 1);
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
