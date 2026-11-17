#include "systemnnn_movie.h"

#include "emberfall/render.hpp"
#include "nnn/game_name_list.hpp"
#include <iconv.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <deque>
#include <limits>
#include <optional>
#include <stdexcept>
#include <type_traits>
#include <utility>
#include <vector>

namespace aether::systemnnn {
namespace fs = std::filesystem;
namespace {
constexpr int audio_rate = 44100;
constexpr std::int64_t max_file_bytes = 8LL * 1024 * 1024 * 1024;
constexpr std::int64_t max_movie_pixels = 4096LL * 2304;
constexpr std::int64_t audio_lead = audio_rate / 4;

void check(int status, const char* operation) {
    if (status >= 0) return;
    char detail[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(status, detail, sizeof(detail));
    throw std::runtime_error(std::string(operation) + ": " + detail);
}

// libiconv on some Apple/Android toolchains uses const char**.
template<class Function>
std::size_t convert(Function function, iconv_t cd, char*& in, std::size_t& left,
                    char*& out, std::size_t& space) {
    if constexpr (std::is_invocable_v<Function, iconv_t, char**, std::size_t*, char**, std::size_t*>)
        return function(cd, &in, &left, &out, &space);
    else {
        const char* constant = in;
        const auto result = function(cd, &constant, &left, &out, &space);
        in = const_cast<char*>(constant);
        return result;
    }
}

std::optional<std::string> cp932_filename(const std::string& utf8) {
    if (utf8.size() > nnn::game_config::max_text_bytes) return {};
    const auto cd = iconv_open("CP932", "UTF-8");
    if (cd == reinterpret_cast<iconv_t>(-1)) throw std::runtime_error("Movie filename CP932 codec unavailable");
    std::string result(utf8.size() * 2 + 8, '\0');
    auto* in = const_cast<char*>(utf8.data());
    auto* out = result.data();
    std::size_t left = utf8.size(), space = result.size();
    const auto status = convert(&iconv, cd, in, left, out, space);
    iconv_close(cd);
    if (status != 0 || left != 0) return {};
    result.resize(result.size() - space);
    return result;
}

bool within(const fs::path& root, const fs::path& path) {
    auto p = path.begin();
    for (const auto& part : root) if (p == path.end() || part != *p++) return false;
    return true;
}

// Also accept original CP932 byte filenames on POSIX. The core helper normally
// compares UTF-8 host filenames through an encoder, which covers Windows too.
fs::path resource_child(const fs::path& root, const std::string& name, bool directory) {
    if (!nnn::resource::valid_component(name) || !fs::is_directory(root)) return {};
    auto found = directory ? nnn::resource::find_directory(root, name, cp932_filename)
                           : nnn::resource::find_file(root, name, cp932_filename);
#ifndef _WIN32
    if (found.empty()) {
        const auto key = nnn::resource::fold_cp932(name);
        for (const auto& entry : fs::directory_iterator(root)) {
            if (nnn::resource::fold_cp932(entry.path().filename().native()) != key) continue;
            if (directory ? entry.is_directory() : entry.is_regular_file()) {
                if (found.empty() || entry.path() < found) found = entry.path();
            }
        }
    }
#endif
    return found;
}

// No FFmpeg URL protocol is used: custom AVIO reads only this already opened file.
// Reject subsidiary opens (playlists, concat, external media/data references).
struct Track {
    AVFormatContext* format = nullptr;
    AVCodecContext* codec = nullptr;
    AVFrame* picture = av_frame_alloc();
    AVPacket* packet = av_packet_alloc();
    AVIOContext* io = nullptr;
    std::FILE* file = nullptr;
    std::int64_t file_size = 0, origin_us = 0, next_us = 0, pts_us = 0, duration_us = 0;
    int stream = -1;
    bool input_eof = false, flush_sent = false, done = false, ready = false;
    bool pending_packet = false;

    ~Track() {
        av_frame_free(&picture);
        av_packet_free(&packet);
        avcodec_free_context(&codec);
        avformat_close_input(&format);
        if (io) { av_freep(&io->buffer); avio_context_free(&io); }
        if (file) std::fclose(file);
    }
    static int read(void* opaque, std::uint8_t* dest, int count) {
        auto& self = *static_cast<Track*>(opaque);
        const auto n = std::fread(dest, 1, static_cast<std::size_t>(count), self.file);
        if (n) return static_cast<int>(n);
        return std::ferror(self.file) ? AVERROR(EIO) : AVERROR_EOF;
    }
    static std::int64_t seek(void* opaque, std::int64_t offset, int whence) {
        auto& self = *static_cast<Track*>(opaque);
        if (whence == AVSEEK_SIZE) return self.file_size;
        whence &= ~AVSEEK_FORCE;
        if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) return AVERROR(EINVAL);
#ifdef _WIN32
        if (_fseeki64(self.file, offset, whence) != 0) return AVERROR(EIO);
        return _ftelli64(self.file);
#else
        if (fseeko(self.file, static_cast<off_t>(offset), whence) != 0) return AVERROR(EIO);
        return static_cast<std::int64_t>(ftello(self.file));
#endif
    }
    static int deny_open(AVFormatContext*, AVIOContext**, const char*, int, AVDictionary**) {
        return AVERROR(EACCES);
    }
    bool open(const fs::path& path, AVMediaType type) {
        file_size = static_cast<std::int64_t>(fs::file_size(path));
#ifdef _WIN32
        file = _wfopen(path.c_str(), L"rb");
#else
        file = std::fopen(path.c_str(), "rb");
#endif
        if (!file) throw std::runtime_error("Cannot open local movie file");
        if (!picture || !packet) throw std::bad_alloc();
        auto* buffer = static_cast<unsigned char*>(av_malloc(32768));
        if (!buffer) throw std::bad_alloc();
        io = avio_alloc_context(buffer, 32768, 0, this, read, nullptr, seek);
        if (!io) { av_free(buffer); throw std::bad_alloc(); }
        format = avformat_alloc_context();
        if (!format) throw std::bad_alloc();
        format->pb = io;
        format->flags |= AVFMT_FLAG_CUSTOM_IO;
        format->io_open = deny_open;
        format->max_streams = 32;
        format->probesize = 2 * 1024 * 1024;
        format->max_analyze_duration = 2000000;
        AVDictionary* options = nullptr;
        av_dict_set(&options, "protocol_whitelist", "", 0);
        const int opened = avformat_open_input(&format, nullptr, nullptr, &options);
        av_dict_free(&options);
        check(opened, "Open movie container");
        check(avformat_find_stream_info(format, nullptr), "Probe movie streams");
        const AVCodec* decoder = nullptr;
        stream = av_find_best_stream(format, type, -1, -1, &decoder, 0);
        if (type == AVMEDIA_TYPE_AUDIO && stream == AVERROR_STREAM_NOT_FOUND) { done = true; return false; }
        check(stream, "Find movie decoder");
        codec = avcodec_alloc_context3(decoder);
        if (!codec) throw std::bad_alloc();
        check(avcodec_parameters_to_context(codec, format->streams[stream]->codecpar), "Movie codec parameters");
        codec->max_pixels = max_movie_pixels;
        codec->thread_count = type == AVMEDIA_TYPE_VIDEO ? 2 : 1;
        codec->err_recognition = AV_EF_CAREFUL | AV_EF_CRCCHECK | AV_EF_EXPLODE;
        check(avcodec_open2(codec, decoder, nullptr), "Open movie decoder");
        if (format->start_time != AV_NOPTS_VALUE) origin_us = format->start_time;
        else {
            auto start = std::numeric_limits<std::int64_t>::max();
            for (unsigned i = 0; i < format->nb_streams; ++i) {
                const auto* s = format->streams[i];
                if ((s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO || s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
                    && s->start_time != AV_NOPTS_VALUE)
                    start = std::min(start, av_rescale_q(s->start_time, s->time_base, AV_TIME_BASE_Q));
            }
            if (start != std::numeric_limits<std::int64_t>::max()) origin_us = start;
        }
        for (unsigned i = 0; i < format->nb_streams; ++i)
            if (i != static_cast<unsigned>(stream)) format->streams[i]->discard = AVDISCARD_ALL;
        return true;
    }

    // Budget covers packet reads, sends and receives, including irrelevant streams.
    bool next(int& budget) {
        if (ready) return true;
        if (done) return false;
        while (budget > 0) {
            --budget;
            const int received = avcodec_receive_frame(codec, picture);
            if (received == AVERROR_EOF) { done = true; return false; }
            if (received >= 0) {
                if ((picture->flags & AV_FRAME_FLAG_CORRUPT) || picture->decode_error_flags)
                    throw std::runtime_error("Corrupt movie frame");
                const auto* selected = format->streams[stream];
                pts_us = picture->best_effort_timestamp == AV_NOPTS_VALUE ? next_us
                    : av_rescale_q(picture->best_effort_timestamp, selected->time_base, AV_TIME_BASE_Q) - origin_us;
#if LIBAVUTIL_VERSION_MAJOR >= 58
                const auto duration = picture->duration;
#else
                const auto duration = picture->pkt_duration;
#endif
                duration_us = duration > 0 ? av_rescale_q(duration, selected->time_base, AV_TIME_BASE_Q) : 0;
                if (codec->codec_type == AVMEDIA_TYPE_AUDIO && picture->sample_rate > 0)
                    duration_us = av_rescale(picture->nb_samples, AV_TIME_BASE, picture->sample_rate);
                if (duration_us <= 0) {
                    const auto rate = av_guess_frame_rate(format, format->streams[stream], picture);
                    duration_us = rate.num > 0 && rate.den > 0
                        ? av_rescale_q(1, av_inv_q(rate), AV_TIME_BASE_Q) : 33333;
                }
                next_us = pts_us + duration_us;
                ready = true;
                return true;
            }
            if (received != AVERROR(EAGAIN)) check(received, "Decode movie frame");
            if (pending_packet) {
                const int sent = avcodec_send_packet(codec, packet);
                if (sent == AVERROR(EAGAIN)) continue;
                check(sent, "Send movie packet");
                av_packet_unref(packet);
                pending_packet = false;
                continue;
            }
            if (input_eof) {
                if (!flush_sent) {
                    const int sent = avcodec_send_packet(codec, nullptr);
                    if (sent == AVERROR(EAGAIN)) continue;
                    check(sent, "Drain movie decoder");
                    flush_sent = true;
                    continue;
                }
                throw std::runtime_error("Movie decoder stalled while draining");
            }
            av_packet_unref(packet);
            const int result = av_read_frame(format, packet);
            if (result == AVERROR_EOF) {
                if (io->error && io->error != AVERROR_EOF) check(io->error, "Read local movie");
                input_eof = true;
                continue;
            }
            check(result, "Read movie packet");
            if (packet->size > 32 * 1024 * 1024) throw std::runtime_error("Movie packet exceeds limit");
            if (packet->flags & AV_PKT_FLAG_CORRUPT) throw std::runtime_error("Corrupt movie packet");
            pending_packet = packet->stream_index == stream;
        }
        return false;
    }
    void consume() { ready = false; av_frame_unref(picture); }
};

struct AudioBlock {
    std::int64_t start = 0;
    std::vector<std::int16_t> pcm;
    std::int64_t end() const { return start + static_cast<std::int64_t>(pcm.size() / 2); }
};
} // namespace

fs::path resolve_movie(const fs::path& root, unsigned number) {
    if (number == 0 || number > 4096) throw std::runtime_error("Invalid one-based movie number");
    const auto base = fs::canonical(root);
    const auto spt = resource_child(base, "spt", true);
    auto list = resource_child(spt, "movielist.xtx", false);
    if (list.empty()) list = resource_child(spt, "movielist.fxf", false);
    if (list.empty()) throw std::runtime_error("Movie list is missing");
    if (!within(base, fs::canonical(list))) throw std::runtime_error("Movie list escapes game root");
    auto text = nnn::game_config::read_text(list);
    if (text.find('\0') != std::string::npos) throw std::runtime_error("Movie list contains a NUL byte");
    const bool unicode = text.compare(0, 3, "\xef\xbb\xbf") == 0;
    if (unicode) {
        const auto converted = cp932_filename(text.substr(3));
        if (!converted) throw std::runtime_error("UTF-8 movie list is not representable in CP932");
        text = *converted;
    }
    std::size_t cursor = 0;
    std::string selected;
    unsigned rows = 0;
    while (const auto name = nnn::game_config::name_token(text, cursor)) {
        if (!nnn::game_config::name_token(text, cursor)) throw std::runtime_error("Movie list has an incomplete row");
        if (++rows > 4096) throw std::runtime_error("Movie list exceeds 4096 entries");
        if (rows == number) selected = std::string(*name);
    }
    if (selected.empty()) throw std::runtime_error("Movie number is absent from movie list");
    const auto normalized = nnn::resource::normalize_cp932_path(selected);
    if (normalized.empty()) throw std::runtime_error("Unsafe movie resource path");
    auto directory = resource_child(base, "movie", true);
    if (directory.empty()) throw std::runtime_error("Movie directory is missing");
    std::size_t start = 0, slash = 0;
    while ((slash = normalized.find('/', start)) != std::string::npos) {
        directory = resource_child(directory, normalized.substr(start, slash - start), true);
        if (directory.empty()) throw std::runtime_error("Movie resource directory is missing");
        start = slash + 1;
    }
    const auto name = normalized.substr(start);
    auto path = resource_child(directory, name, false);
    if (path.empty()) {
        std::size_t dot = std::string::npos;
        for (std::size_t i = 0; i < name.size(); ++i) {
            if (nnn::resource::cp932_lead(static_cast<unsigned char>(name[i])) && i + 1 < name.size()) ++i;
            else if (name[i] == '.') dot = i;
        }
        const auto stem = dot == std::string::npos ? name : name.substr(0, dot);
        for (const char* ext : {".wmv", ".mpg", ".mpeg", ".avi", ".mp4", ".m4v", ".mov", ".mkv", ".webm"}) {
            path = resource_child(directory, stem + ext, false);
            if (!path.empty()) break;
        }
    }
    if (path.empty()) throw std::runtime_error("Movie resource was not found");
    path = fs::canonical(path);
    if (!within(base, path)) throw std::runtime_error("Movie resource escapes game root");
    const auto size = fs::file_size(path);
    if (size == 0 || size > static_cast<std::uint64_t>(max_file_bytes)) throw std::runtime_error("Movie file size is invalid");
    return path;
}

struct MoviePlayer::Impl {
    std::unique_ptr<Track> video, audio;
    AVFrame* latest_video = av_frame_alloc();
    SwsContext* scale = nullptr;
    SwrContext* resampler = nullptr;
    AVChannelLayout input_layout{};
    int input_rate = 0, input_format = -1;
    emberfall::render::Surface surface;
    std::deque<AudioBlock> blocks;
    std::int64_t clock_us = 0, video_end_us = 0, audio_end_sample = 0;
    std::int64_t sample_cursor = 0, output_cursor = 0;
    bool opened = false, paused = false, have_frame = false, samples_started = false, resampler_done = false;
    std::string failure;
    ~Impl() { av_frame_free(&latest_video); sws_freeContext(scale); swr_free(&resampler); av_channel_layout_uninit(&input_layout); }
    std::int64_t clock_sample() const { return av_rescale(clock_us, audio_rate, AV_TIME_BASE); }
    void discard_old() {
        const auto now = clock_sample();
        while (!blocks.empty() && blocks.front().end() <= now) blocks.pop_front();
        output_cursor = std::max(output_cursor, now);
    }
    void present() {
        auto* f = latest_video;
        if (f->width <= 0 || f->height <= 0 || f->width > 8192 || f->height > 8192
            || static_cast<std::int64_t>(f->width) * f->height > max_movie_pixels)
            throw std::runtime_error("Movie dimensions exceed the limit");
        scale = sws_getCachedContext(scale, f->width, f->height, static_cast<AVPixelFormat>(f->format),
            f->width, f->height, AV_PIX_FMT_RGB24, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!scale) throw std::runtime_error("Movie RGB converter allocation failed");
        const auto* colors = sws_getCoefficients(f->colorspace == AVCOL_SPC_UNSPECIFIED ? SWS_CS_DEFAULT : f->colorspace);
        if (colors) check(sws_setColorspaceDetails(scale, colors, f->color_range == AVCOL_RANGE_JPEG,
            colors, 1, 0, 1 << 16, 1 << 16), "Movie color conversion");
        surface.width = static_cast<unsigned>(f->width);
        surface.height = static_cast<unsigned>(f->height);
        surface.rgb.resize(static_cast<std::size_t>(f->width) * f->height * 3);
        std::uint8_t* pixels[4] = {surface.rgb.data(), nullptr, nullptr, nullptr};
        int stride[4] = {f->width * 3, 0, 0, 0};
        if (sws_scale(scale, f->data, f->linesize, 0, f->height, pixels, stride) != f->height)
            throw std::runtime_error("Movie RGB conversion was incomplete");
        have_frame = true;
    }
    void append(const std::uint8_t** data, int count, int capacity) {
        if (capacity < 0 || capacity > 200000) throw std::runtime_error("Movie resampler output exceeds limit");
        AudioBlock block;
        block.start = sample_cursor;
        block.pcm.resize(static_cast<std::size_t>(capacity) * 2);
        auto* output = reinterpret_cast<std::uint8_t*>(block.pcm.data());
        const int frames = swr_convert(resampler, &output, capacity, data, count);
        check(frames, "Resample movie audio");
        block.pcm.resize(static_cast<std::size_t>(frames) * 2);
        sample_cursor += frames;
        audio_end_sample = std::max(audio_end_sample, sample_cursor);
        if (frames && block.end() > clock_sample()) blocks.push_back(std::move(block));
        if (blocks.size() > 256) throw std::runtime_error("Movie PCM queue exceeds limit");
    }
    void drain_resampler() {
        if (!resampler || resampler_done) { resampler_done = true; return; }
        // A single decoded audio frame is at most 32768 samples; this bound also
        // covers all delayed resampler output. Repeated drains terminate at zero.
        for (int i = 0; i < 8; ++i) {
            const auto before = sample_cursor;
            append(nullptr, 0, 16384);
            if (sample_cursor == before) { resampler_done = true; return; }
        }
        throw std::runtime_error("Movie resampler did not drain");
    }
    void convert_audio() {
        const auto* f = audio->picture;
        if (f->sample_rate < 8000 || f->sample_rate > 192000 || f->nb_samples < 0 || f->nb_samples > 32768
            || f->ch_layout.nb_channels < 1 || f->ch_layout.nb_channels > 8)
            throw std::runtime_error("Movie audio format exceeds limits");
        const auto expected = av_rescale(audio->pts_us, audio_rate, AV_TIME_BASE);
        const bool changed = !resampler || input_rate != f->sample_rate || input_format != f->format
            || av_channel_layout_compare(&input_layout, &f->ch_layout) != 0;
        // PTS jumps preserve gaps/overlaps instead of running the sound early.
        const auto delayed = resampler ? av_rescale(swr_get_delay(resampler, input_rate), audio_rate, input_rate) : 0;
        const bool discontinuity = samples_started && std::abs(expected - (sample_cursor + delayed)) > audio_rate / 10;
        if (changed || discontinuity) {
            drain_resampler();
            swr_free(&resampler);
            av_channel_layout_uninit(&input_layout);
            check(av_channel_layout_copy(&input_layout, &f->ch_layout), "Copy movie channel layout");
            AVChannelLayout effective_layout{};
            if (input_layout.order == AV_CHANNEL_ORDER_UNSPEC)
                av_channel_layout_default(&effective_layout, input_layout.nb_channels);
            AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
            check(swr_alloc_set_opts2(&resampler, &stereo, AV_SAMPLE_FMT_S16, audio_rate,
                effective_layout.nb_channels ? &effective_layout : &input_layout,
                static_cast<AVSampleFormat>(f->format), f->sample_rate, 0, nullptr), "Configure movie resampler");
            check(swr_init(resampler), "Initialize movie resampler");
            input_rate = f->sample_rate;
            input_format = f->format;
            sample_cursor = expected;
            samples_started = true;
            resampler_done = false;
        }
        const auto capacity = av_rescale_rnd(swr_get_delay(resampler, input_rate) + f->nb_samples,
            audio_rate, input_rate, AV_ROUND_UP);
        std::array<const std::uint8_t*, 8> planes{};
        std::copy_n(f->extended_data, av_sample_fmt_is_planar(static_cast<AVSampleFormat>(f->format))
            ? f->ch_layout.nb_channels : 1, planes.begin());
        append(planes.data(), f->nb_samples, static_cast<int>(capacity));
    }
    void pump_audio(int budget, std::int64_t target) {
        if (!audio || audio->done) { drain_resampler(); return; }
        int frames = 0;
        while (frames++ < 64 && budget > 0) {
            if (!audio->next(budget)) break;
            if (av_rescale(audio->pts_us, audio_rate, AV_TIME_BASE) > target) break;
            convert_audio();
            audio->consume();
        }
        if (audio->done) drain_resampler();
    }
    void pump_video(int budget) {
        int frames = 0;
        while (frames++ < 32 && budget > 0) {
            if (!video->next(budget)) break;
            if (video->pts_us > clock_us) break;
            // Retain the most recent due frame and convert only once per tick,
            // including the final frame after a large clock jump.
            if (!latest_video) throw std::bad_alloc();
            av_frame_unref(latest_video);
            check(av_frame_ref(latest_video, video->picture), "Retain movie frame");
            video_end_us = std::max(video_end_us, video->pts_us + video->duration_us);
            video->consume();
        }
        if (latest_video && latest_video->data[0]) {
            present();
            av_frame_unref(latest_video);
        }
        if (video->done && !have_frame) throw std::runtime_error("Movie contains no decodable video frames");
    }
    bool ended() const {
        return opened && failure.empty() && video->done && (!audio || (audio->done && resampler_done))
            && clock_us >= video_end_us && clock_sample() >= audio_end_sample;
    }
};

MoviePlayer::MoviePlayer() : impl_(std::make_unique<Impl>()) {}
MoviePlayer::~MoviePlayer() = default;
bool MoviePlayer::open(const fs::path& path, std::string& error) {
    close();
    try {
        if (path.empty() || path.native().find(fs::path::value_type{}) != fs::path::string_type::npos
            || !fs::is_regular_file(path)) throw std::runtime_error("Movie is not a local regular file");
        const auto size = fs::file_size(path);
        if (size == 0 || size > static_cast<std::uint64_t>(max_file_bytes)) throw std::runtime_error("Movie file size is invalid");
        impl_->video = std::make_unique<Track>();
        impl_->video->open(path, AVMEDIA_TYPE_VIDEO);
        impl_->audio = std::make_unique<Track>();
        if (!impl_->audio->open(path, AVMEDIA_TYPE_AUDIO)) impl_->audio.reset();
        impl_->opened = true;
        tick(0);
        if (!impl_->failure.empty()) throw std::runtime_error(impl_->failure);
        error.clear();
        return true;
    } catch (const std::exception& e) {
        error = e.what();
        close();
        impl_->failure = error;
        return false;
    }
}
void MoviePlayer::tick(std::uint32_t elapsed_ms) {
    auto& p = *impl_;
    if (!p.opened || p.paused || !p.failure.empty() || p.ended()) return;
    try {
        p.clock_us = std::min<std::int64_t>(p.clock_us + static_cast<std::int64_t>(elapsed_ms) * 1000,
            std::numeric_limits<std::int64_t>::max() / 4);
        p.discard_old();
        p.pump_video(512);
        p.pump_audio(512, p.clock_sample() + audio_lead);
    } catch (const std::exception& e) { p.failure = e.what(); }
}
const emberfall::render::Surface* MoviePlayer::frame() const { return impl_->have_frame ? &impl_->surface : nullptr; }
void MoviePlayer::pull(std::int16_t* output, std::size_t frames) {
    if (!output || frames > std::numeric_limits<std::size_t>::max() / 2) return;
    std::fill_n(output, frames * 2, std::int16_t{0});
    auto& p = *impl_;
    if (!p.opened || p.paused || !p.failure.empty() || !p.audio || p.ended()) return;
    try {
        p.discard_old();
        const auto available = std::max<std::int64_t>(0, p.clock_sample() + audio_lead - p.output_cursor);
        const auto count = std::min<std::size_t>(frames, static_cast<std::size_t>(available));
        p.pump_audio(128, p.output_cursor + static_cast<std::int64_t>(count));
        const auto begin = p.output_cursor, end = begin + static_cast<std::int64_t>(count);
        for (const auto& block : p.blocks) {
            const auto first = std::max(begin, block.start), last = std::min(end, block.end());
            if (first >= last) continue;
            std::copy_n(block.pcm.data() + (first - block.start) * 2, static_cast<std::size_t>(last - first) * 2,
                output + (first - begin) * 2);
        }
        p.output_cursor = end;
        while (!p.blocks.empty() && p.blocks.front().end() <= end) p.blocks.pop_front();
    } catch (const std::exception& e) {
        std::fill_n(output, frames * 2, std::int16_t{0});
        p.failure = e.what();
    }
}
void MoviePlayer::pause(bool paused) { impl_->paused = paused; }
bool MoviePlayer::ended() const { return impl_->ended(); }
void MoviePlayer::close() { impl_ = std::make_unique<Impl>(); }
std::string MoviePlayer::error() const { return impl_->failure; }
bool MoviePlayer::active() const { return impl_->opened; }

} // namespace aether::systemnnn
