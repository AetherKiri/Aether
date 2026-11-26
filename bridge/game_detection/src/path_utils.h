#pragma once

#include <string>
#include <string_view>

namespace aether::game_detection::paths {

inline std::string Join(const std::string &base, std::string_view relative) {
    if (base.empty() || base.back() == '/' || base.back() == '\\') {
        return base + std::string(relative);
    }
    return base + "/" + std::string(relative);
}

inline std::string_view FileName(std::string_view path) {
    const auto slash = path.find_last_of("/\\");
    return slash == path.npos ? path : path.substr(slash + 1);
}

inline std::string Parent(std::string_view path) {
    const auto slash = path.find_last_of("/\\");
    if (slash == path.npos) {
        return {};
    }
    const auto scheme = path.find("://");
    const bool root = slash == 0 || path[slash - 1] == ':' ||
                      (scheme != path.npos && slash == scheme + 2);
    return std::string(path.substr(0, slash + root));
}

inline std::string_view Extension(std::string_view name) {
    name = FileName(name);
    const auto dot = name.rfind('.');
    return dot == name.npos ? std::string_view{} : name.substr(dot + 1);
}

inline std::string_view Trim(std::string_view text) {
    while (!text.empty() && static_cast<unsigned char>(text.front()) <= 32) {
        text.remove_prefix(1);
    }
    while (!text.empty() && static_cast<unsigned char>(text.back()) <= 32) {
        text.remove_suffix(1);
    }
    return text;
}

} // namespace aether::game_detection::paths
