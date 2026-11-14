#pragma once
#include <filesystem>
#include <string>

namespace aether::text {
// A fresh snapshot for one game. Empty values preserve the runtime's native
// configuration/translation defaults. Paths remain inside the game directory.
struct GameTextSettings {
    std::string encoding;
    std::filesystem::path font;
    static GameTextSettings Load(const std::filesystem::path& root,
                                 const std::string& engine);
};
} // namespace aether::text
