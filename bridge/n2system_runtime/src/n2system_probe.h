#pragma once
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <string>
#include <unordered_map>
#include <nlohmann/json.hpp>

namespace aetherkiri::n2system::detail {
inline bool IsNpa(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    char bytes[7]{};
    input.read(bytes, sizeof(bytes));
    return input.gcount() == sizeof(bytes) &&
        std::string(bytes, sizeof(bytes)) == std::string("NPA\1\0\0\0", 7);
}
inline bool IsLegacyPak(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    unsigned char header[0x108]{};
    input.read(reinterpret_cast<char*>(header), sizeof(header));
    return input.gcount() == sizeof(header) && header[0] == 3 && header[1] == 0 &&
        header[2] == 0 && header[3] == 0 && header[0x104] == 100 &&
        header[0x105] == 0 && header[0x106] == 0 && header[0x107] == 0;
}
inline int ProbeRoot(const char* root) {
    if(!root || !*root) return 0;
    try {
        const auto directory = std::filesystem::u8path(root);
        if(!std::filesystem::is_directory(directory)) return 0;
        std::unordered_map<std::string, std::filesystem::path> files;
        for(const auto& file : std::filesystem::directory_iterator(directory)) {
            if(!file.is_regular_file()) continue;
            auto name = file.path().filename().u8string();
            std::transform(name.begin(), name.end(), name.begin(),
                [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
            files.emplace(name, file.path());
        }
        // Explicit adapter manifests retain recognition even when malformed,
        // so opening them can report the actionable profile error.
        if(files.count("aether-n2system.json")) return 95;
        if(files.count("nss.npa") && files.count("system.npa") &&
           IsNpa(files.at("nss.npa")) && IsNpa(files.at("system.npa"))) return 90;
        if(files.count("script.pak") && files.count("system.pak") &&
           (files.count("sys.ini") || files.count("sys_cn.ini")) &&
           (files.count("game.ini") || files.count("game_cn.ini")) &&
           IsLegacyPak(files.at("script.pak")) && IsLegacyPak(files.at("system.pak"))) return 90;
        if(!files.count("profiles.json")) return 0;
        std::ifstream input(files.at("profiles.json"));
        const auto profile = nlohmann::json::parse(input, nullptr, false);
        if(!profile.is_object() || !profile.contains("activeProfile")) return 0;
        nlohmann::json selected;
        const auto& active = profile["activeProfile"];
        if(active.is_string()) {
            if(!profile.contains("profiles") || !profile["profiles"].is_object() ||
               !profile["profiles"].contains(active.get<std::string>())) return 0;
            selected = profile["profiles"][active.get<std::string>()];
            if(!selected.is_object()) return 0;
        } else if(!active.is_null()) return 0;
        auto property = [&](const char* key) -> nlohmann::json {
            if(selected.is_object() && selected.contains(key)) return selected[key];
            return profile.contains(key) ? profile[key] : nlohmann::json();
        };
        // These dotted NitroSharp properties distinguish an intentional game
        // profile from unrelated applications' generic profiles.json files.
        // Missing game assets remain an open error rather than hiding a game.
        return property("product.name").is_string() &&
               property("designResolution").is_string() ? 90 : 0;
    } catch(...) {}
    return 0;
}
}
