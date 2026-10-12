#include "flash_player.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/audio_stream_player.hpp>
#include <godot_cpp/classes/audio_stream_generator.hpp>
#include <godot_cpp/classes/audio_stream_generator_playback.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <vector>

#if defined(AETHERKIRI_WITH_FLASH)
extern "C" {
void *aether_flash_open(const char *, const char *);
void aether_flash_close(void *);
const char *aether_flash_error();
uint32_t aether_flash_width(const void *);
uint32_t aether_flash_height(const void *);
bool aether_flash_tick(void *, double, uint8_t *, size_t);
bool aether_flash_audio(const void *, float *, size_t);
bool aether_flash_font(void *, const char *);
void aether_flash_pause(void *, bool);
bool aether_flash_input(void *, uint32_t, double, double, uint32_t, uint32_t);
}
#endif

namespace godot {
class AetherFlashPlayer : public Node {
    GDCLASS(AetherFlashPlayer, Node)
    void *handle_ = nullptr;
    Ref<ImageTexture> texture_;
    PackedByteArray pixels_;
    AudioStreamPlayer *audio_ = nullptr;
    Ref<AudioStreamGeneratorPlayback> playback_;
    int width_ = 0, height_ = 0;
    bool paused_ = false;
    double render_elapsed_ = 0;
    String error_;

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("is_supported"), &AetherFlashPlayer::is_supported);
        ClassDB::bind_method(D_METHOD("open", "path", "storage"), &AetherFlashPlayer::open);
        ClassDB::bind_method(D_METHOD("close"), &AetherFlashPlayer::close);
        ClassDB::bind_method(D_METHOD("get_texture"), &AetherFlashPlayer::get_texture);
        ClassDB::bind_method(D_METHOD("get_error"), &AetherFlashPlayer::get_error);
        ClassDB::bind_method(D_METHOD("set_default_font", "path"), &AetherFlashPlayer::set_default_font);
        ClassDB::bind_method(D_METHOD("set_paused", "paused"), &AetherFlashPlayer::set_paused);
        ClassDB::bind_method(D_METHOD("send_input", "kind", "x", "y", "code", "unicode"), &AetherFlashPlayer::send_input);
        ADD_SIGNAL(MethodInfo("playback_error", PropertyInfo(Variant::STRING, "message")));
    }
public:
    ~AetherFlashPlayer() override { close(); }
    bool is_supported() const {
#if defined(AETHERKIRI_WITH_FLASH)
        return true;
#else
        return false;
#endif
    }
    bool open(const String &path, const String &storage) {
        close();
        error_ = "";
#if defined(AETHERKIRI_WITH_FLASH)
        handle_ = aether_flash_open(path.utf8().get_data(), storage.utf8().get_data());
        if (!handle_) { error_ = String::utf8(aether_flash_error()); return false; }
        width_ = aether_flash_width(handle_);
        height_ = aether_flash_height(handle_);
        pixels_.resize(int64_t(width_) * height_ * 4);
        if (!aether_flash_tick(handle_, 0, pixels_.ptrw(), pixels_.size())) {
            error_ = String::utf8(aether_flash_error()); close(); return false;
        }
        texture_ = ImageTexture::create_from_image(Image::create_from_data(width_, height_, false, Image::FORMAT_RGBA8, pixels_));
        Ref<AudioStreamGenerator> stream;
        stream.instantiate();
        stream->set_mix_rate(44100);
        stream->set_buffer_length(0.1);
        audio_ = memnew(AudioStreamPlayer);
        add_child(audio_);
        audio_->set_stream(stream);
        audio_->play();
        playback_ = audio_->get_stream_playback();
        paused_ = false;
        render_elapsed_ = 0;
        set_process(true);
        return true;
#else
        error_ = "Flash playback is not included in this build";
        return false;
#endif
    }
    void close() {
        set_process(false);
        playback_.unref();
        if (audio_) { audio_->stop(); remove_child(audio_); memdelete(audio_); audio_ = nullptr; }
#if defined(AETHERKIRI_WITH_FLASH)
        if (handle_) { aether_flash_close(handle_); handle_ = nullptr; }
#endif
        texture_.unref();
        pixels_.clear();
    }
    Ref<Texture2D> get_texture() const { return texture_; }
    String get_error() const { return error_; }
    bool set_default_font(const String &path) {
#if defined(AETHERKIRI_WITH_FLASH)
        return handle_ && aether_flash_font(handle_, path.utf8().get_data());
#else
        return false;
#endif
    }
    void set_paused(bool paused) {
        paused_ = paused;
#if defined(AETHERKIRI_WITH_FLASH)
        if (handle_) aether_flash_pause(handle_, paused);
#endif
        if (audio_) audio_->set_stream_paused(paused);
    }
    bool send_input(int kind, double x, double y, int code, int unicode) {
#if defined(AETHERKIRI_WITH_FLASH)
        return handle_ && !paused_ && aether_flash_input(handle_, kind, x, y, code, unicode);
#else
        return false;
#endif
    }
    void _process(double delta) override {
#if defined(AETHERKIRI_WITH_FLASH)
        if (!handle_ || paused_) return;
        render_elapsed_ += delta;
        if (render_elapsed_ >= 1.0 / 60.0) {
            if (!aether_flash_tick(handle_, render_elapsed_ * 1000, pixels_.ptrw(), pixels_.size())) {
                error_ = String::utf8(aether_flash_error());
                close();
                emit_signal("playback_error", error_);
                return;
            }
            render_elapsed_ = 0;
            texture_->update(Image::create_from_data(width_, height_, false, Image::FORMAT_RGBA8, pixels_));
        }
        if (playback_.is_valid()) {
            const int frames = std::min(4096, playback_->get_frames_available());
            if (frames > 0) {
                std::vector<float> samples(frames * 2);
                if (aether_flash_audio(handle_, samples.data(), frames)) {
                    PackedVector2Array output;
                    output.resize(frames);
                    for (int i = 0; i < frames; ++i) output.set(i, Vector2(samples[i*2], samples[i*2+1]));
                    playback_->push_buffer(output);
                }
            }
        }
#endif
    }
};
void RegisterAetherFlashPlayer() { ClassDB::register_class<AetherFlashPlayer>(); }
}
