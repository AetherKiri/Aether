#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace emberfall::render { struct Surface; }

namespace aether::systemnnn {

// One-based spt/movielist.xtx entry, with encrypted FXF fallback. Resolves only
// regular files inside root/movie, matching ASCII case and raw CP932 names.
// Throws on invalid/missing entries, unsafe paths, or missing movie files.
std::filesystem::path resolve_movie(const std::filesystem::path& root, unsigned one_based_number);

// Portable FFmpeg player. All calls, including use of frame(), must be serialized
// by the owner (the provider game mutex). No worker, audio device, or window.
// tick is the sole playback clock; call it even when audio output is disabled.
// Decoding is bounded per call; large elapsed times catch up over subsequent ticks.
class MoviePlayer {
public:
    MoviePlayer();
    ~MoviePlayer();
    MoviePlayer(const MoviePlayer&) = delete;
    MoviePlayer& operator=(const MoviePlayer&) = delete;

    bool open(const std::filesystem::path& path, std::string& error);
    void tick(std::uint32_t elapsed_ms);
    const emberfall::render::Surface* frame() const;
    // Always writes stereo interleaved PCM16, 44100 Hz; unavailable audio is silence.
    // Paused pulls do not consume samples. Output may lead tick by at most 250 ms.
    void pull(std::int16_t* output, std::size_t frames);
    void pause(bool paused);
    bool ended() const;
    void close();
    std::string error() const;
    // Remains true at EOF or on error until close; ended is true only at clean EOF.
    // Decoder errors freeze playback and remain available for the owner to warn.
    bool active() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace aether::systemnnn
