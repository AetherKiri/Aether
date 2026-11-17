#pragma once
#include "systemnnn_minigame.h"
#include "emberfall/game_session.hpp"
#include <memory>
#include <string>
#include <vector>

namespace aether::systemnnn {
// Owns only UI state. GameSession lifetime remains with the provider.
class MiniGameBinding {
public:
    struct Result { bool progress_changed=false,exit=false; std::vector<std::string> warnings; };
    MiniGameBinding();
    ~MiniGameBinding();
    MiniGameBinding(const MiniGameBinding&)=delete;
    MiniGameBinding& operator=(const MiniGameBinding&)=delete;
    // Zero-based configured entry. Throws on invalid/unavailable configuration.
    void start(unsigned index,emberfall::scene::GameSession& game,std::string caller="title",std::uint64_t seed=0);
    bool active() const noexcept;
    void pointer(minigame::Pointer event,float x,float y,int button=0);
    void tick(std::uint32_t milliseconds);
    emberfall::render::Surface render() const;
    // Applies real completion and SE; consumes one-shot frontend events.
    // On exit also stops frontend and restores caller music. Persist progress when true.
    Result dispatch(emberfall::scene::GameSession& game);
    void stop(emberfall::scene::GameSession& game,bool restore_music=true);
    const minigame::Frontend* frontend() const noexcept;
    std::vector<std::string> take_warnings();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace aether::systemnnn
