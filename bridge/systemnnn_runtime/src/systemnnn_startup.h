#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace emberfall::scene { class GameSession; struct SessionOptions; }
namespace emberfall::render { struct Surface; }

namespace aether::systemnnn {

struct StartupMovieRequest {
    // Original game-encoded bytes. movie_number is the 1-based movielist row,
    // or zero for movieFileName. The parent resolves/plays this through MoviePlayer.
    std::string filename;
    unsigned movie_number=0;
    bool skippable=true;
    bool fill_exit_screen=true;
    std::uint32_t exit_color=0; // 0xRRGGBB.
};

// Worker-thread startup controller. Serialize every call (including session audio
// access) with the parent game_mutex. It never steps the main story session.
class StartupSequence {
public:
    explicit StartupSequence(const std::filesystem::path& root);
    ~StartupSequence();
    StartupSequence(const StartupSequence&)=delete;
    StartupSequence& operator=(const StartupSequence&)=delete;

    // Optional cache peer MUST be another create_ui_preview session, not shared.
    void start(emberfall::scene::GameSession& shared,
               const emberfall::scene::GameSession* decorative_asset_peer=nullptr);
    void start(emberfall::scene::GameSession& shared,
               const emberfall::scene::SessionOptions& options,
               const emberfall::scene::GameSession* decorative_asset_peer=nullptr);
    void tick(std::uint32_t dt_ms,bool advance);
    bool finished() const noexcept;
    bool awaiting_movie() const noexcept;
    const std::optional<StartupMovieRequest>& movie_request() const noexcept;
    void finish_movie(); // Call on completion, user skip, or playback failure.

    // When awaiting_title(), prepare the normal title session/Presenter once and
    // pass its complete composed RGB frame. The entrance freezes that snapshot;
    // normal title stepping/controls begin when finished() becomes true.
    bool awaiting_title() const noexcept;
    void begin_title(const emberfall::render::Surface& composed_title);
    const emberfall::render::Surface* frame() const noexcept;
    emberfall::scene::GameSession* session() noexcept; // Decorative background.
    emberfall::scene::GameSession* audio_session() noexcept; // Shared main session (BGM).
    const std::vector<std::string>& warnings() const noexcept;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace aether::systemnnn
