#pragma once

#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace emberfall::scene { class GameSession; }
namespace emberfall::render { struct MessagePlane; struct Texture; }

namespace aether::systemnnn {
class TextRenderer;

// Optional host inventory. Slot numbers are one based; title/timestamp are UTF-8.
// Thumbnail pixels are straight RGBA in the normal session Texture format.
struct SaveSlotInfo {
    int slot=0;
    bool occupied=false;
    std::string title,timestamp;
    std::shared_ptr<const emberfall::render::Texture> thumbnail;
};

// Raw configuration values retain the game encoding; decode labels with
// TextRenderer::decode(value, true). Keys are ASCII case insensitive.
class Config {
public:
    bool has(std::string_view key) const;
    std::string value(std::string_view key, std::string_view fallback = {}) const;
    int number(std::string_view key, int fallback = 0) const;
    const std::unordered_map<std::string, std::string>& fields() const noexcept { return values_; }
private:
    friend class Presenter;
    std::unordered_map<std::string, std::string> values_;
};

// Worker-thread presenter. It only renders and records hit targets: the host
// owns session stepping, menu/background scripts, persistence and action dispatch.
// Returned planes are transparent, premultiplied RGBA at the game resolution.
class Presenter {
public:
    Presenter(const std::filesystem::path& root, TextRenderer& text);
    ~Presenter();
    Presenter(const Presenter&) = delete;
    Presenter& operator=(const Presenter&) = delete;

    std::shared_ptr<emberfall::render::MessagePlane> render(
        emberfall::scene::GameSession& game, std::string_view overlay = {});
    // Call exactly once on entry to a new dialogue sequence, before ticking its
    // native text clock. Preserves APPEND prefixes; does not reset voice timing.
    void prepare_text(emberfall::scene::GameSession& game);
    // Coordinates are in logical game pixels. Empty means no enabled target.
    // choice/place/slot indices are ONE based; modal uses ScriptModalRow::id.
    // Pagination: page:prev/page:next; engine modal pages: modal:page:N.
    // Exact engine protocol: modal:action:A:V -> act_modal(request,A,V).
    // A: Back=0 Choose=1 Page=2 Hover=3 Confirm=4 Group=5 Resume=6 Scroll=7 Commit=8.
    // Chart Choose uses signed packed logical XY, NOT a node id.
    // A chart result 4 (LeaveReady) requires host Commit=8 after its exit effect.
    // Minigames: minigame:N uses the ZERO-based minigame registration index.
    // Title and omake/extras overlays honor their own miniGameFlag and caller gates.
    // Settings: param:ID:VALUE (host applies a SystemNNN runtime parameter).
    std::string hit(int x, int y) const;
    void set_page(int page) noexcept;
    int page() const noexcept;
    // An empty supplied inventory means all slots are known empty; before the
    // first call occupancy is unknown and load targets stay enabled.
    void set_save_slots(std::vector<SaveSlotInfo> slots);

    const Config& title_config() const noexcept;
    std::string title_background() const; // sys/ resource key; empty for scripted title
    std::string title_script() const;     // raw game bytes, passed to GameSession
    bool title_script_loop() const;
    const std::vector<std::string>& diagnostics() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace aether::systemnnn
