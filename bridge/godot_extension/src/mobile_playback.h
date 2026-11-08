#pragma once

#include "engine_api.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace aetherkiri {

// Main-thread owner of a borrowed runtime during AVKit playback. It deliberately
// bypasses the Godot tick/presentation path, which may submit GPU commands.
class MobilePlayback {
public:
    bool Bind(engine_handle_t engine) {
        if (engine == engine_) return engine_ != nullptr;
        Unbind();
        if (engine && engine_background_playback(engine, ENGINE_BACKGROUND_PLAYBACK_QUERY) == ENGINE_RESULT_OK)
            engine_ = engine;
        return engine_ != nullptr;
    }
    bool Matches(engine_handle_t engine) const { return engine_ && engine_ == engine; }
    bool Supported() const { return engine_ != nullptr; }
    bool Entered() const { return entered_; }
    bool Enter() {
        if (!engine_) return false;
        if (entered_) return true;
        // Freeze first: ENTER may migrate foreground resources. A rejected
        // migration must leave the runtime paused, never running GPU work.
        if (engine_pause(engine_) != ENGINE_RESULT_OK) return false;
        paused_ = true;
        if (engine_background_playback(engine_, ENGINE_BACKGROUND_PLAYBACK_ENTER) != ENGINE_RESULT_OK)
            return false;
        entered_ = true;
        last_serial_ = UINT64_MAX;
        return true;
    }
    bool Play(bool playing) {
        if (!engine_ || !entered_) return false;
        if (paused_ == !playing) return true;
        const auto result = playing ? engine_resume(engine_) : engine_pause(engine_);
        if (result != ENGINE_RESULT_OK) return false;
        paused_ = !playing;
        remainder_ms_ = 0;
        return true;
    }
    bool Restore() {
        if (!engine_) return false;
        if (entered_) {
            if (!Play(false)) return false;
            if (engine_background_playback(engine_, ENGINE_BACKGROUND_PLAYBACK_LEAVE) != ENGINE_RESULT_OK)
                return false;
            entered_ = false;
        }
        if (paused_) {
            if (engine_resume(engine_) != ENGINE_RESULT_OK) return false;
            paused_ = false;
        }
        return true;
    }
    void Unbind(bool foreground = true) {
        if (engine_) {
            if (foreground) Restore();
            else engine_pause(engine_); // Teardown must not reactivate audio/GPU in background.
        }
        engine_ = nullptr;
        entered_ = false;
        paused_ = false;
        pixels_.clear();
    }
    bool Advance(double seconds, bool& new_frame) {
        new_frame = false;
        if (!engine_ || !entered_ || paused_) return false;
        if (!std::isfinite(seconds) || seconds < 0) return false;
        // Timer stalls must not fast-forward story/choices on return.
        const double elapsed = std::clamp(seconds * 1000.0, 0.0, 250.0) + remainder_ms_;
        const auto delta = static_cast<uint32_t>(elapsed);
        remainder_ms_ = elapsed - delta;
        if (engine_tick(engine_, delta) != ENGINE_RESULT_OK) return false;
        engine_frame_desc_t desc{};
        desc.struct_size = sizeof(desc);
        if (engine_get_frame_desc(engine_, &desc) != ENGINE_RESULT_OK) return false;
        if (!desc.width || !desc.height || desc.width > 8192 || desc.height > 8192 ||
            desc.pixel_format != ENGINE_PIXEL_FORMAT_RGBA8888 || desc.stride_bytes < uint64_t(desc.width) * 4 ||
            uint64_t(desc.stride_bytes) * desc.height > 128u * 1024u * 1024u) return false;
        if (last_serial_ == desc.frame_serial && desc.width == frame_.width &&
            desc.height == frame_.height && desc.stride_bytes == frame_.stride_bytes) return true;
        pixels_.resize(size_t(desc.stride_bytes) * desc.height);
        if (engine_read_frame_rgba(engine_, pixels_.data(), pixels_.size()) != ENGINE_RESULT_OK) return false;
        frame_ = desc;
        last_serial_ = desc.frame_serial;
        new_frame = true;
        return true;
    }
    const engine_frame_desc_t& Frame() const { return frame_; }
    const uint8_t* Pixels() const { return pixels_.data(); }
private:
    engine_handle_t engine_ = nullptr;
    bool entered_ = false, paused_ = false;
    double remainder_ms_ = 0;
    uint64_t last_serial_ = UINT64_MAX;
    engine_frame_desc_t frame_{};
    std::vector<uint8_t> pixels_;
};
}
