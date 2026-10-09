#pragma once

#include <filesystem>

namespace aetherkiri::renpy {
inline bool HasRenpyProject(const std::filesystem::path& root) {
    namespace fs = std::filesystem;
    std::error_code ec;
    if (!fs::is_directory(root, ec)) return false;
    // Match the desktop distributor's supported directory layouts.
    return (fs::is_directory(root / "game", ec) &&
            (fs::exists(root / "game" / "script.rpy", ec) ||
             fs::exists(root / "game" / "script.rpyc", ec) ||
             fs::exists(root / "game" / "options.rpy", ec))) ||
           fs::exists(root / "script.rpy", ec);
}
} // namespace aetherkiri::renpy
