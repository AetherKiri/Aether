#include "AetherGameTextSettings.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace aether::text {
GameTextSettings GameTextSettings::Load(const std::filesystem::path& directory,
                                       const std::string& engine) {
    const std::vector<std::string> engines = {"onscripter", "yuris", "systemc",
        "rfvp", "bgi", "advhd", "escude", "softpal", "catsystem2", "entisgls"};
    GameTextSettings result;
    if(std::find(engines.begin(), engines.end(), engine) == engines.end()) return result;
    const auto root = std::filesystem::canonical(directory);
    const auto path = root / "aether_config.json";
    if(!std::filesystem::exists(path)) return result;
    try {
        if(std::filesystem::file_size(path) > 1024 * 1024)
            throw std::runtime_error("configuration exceeds 1 MiB");
        std::ifstream stream(path);
        const auto document = nlohmann::json::parse(stream);
        if(!document.is_object()) throw std::runtime_error("expected an object");
        if(!document.contains("text")) return result;
        const auto& text = document.at("text");
        if(!text.is_object()) throw std::runtime_error("text must be an object");
        result.encoding = text.value("encoding", std::string{});
        const std::vector<std::string> encodings = engine == "entisgls"
            ? std::vector<std::string>{""}
            : engine == "onscripter" || engine == "rfvp"
                ? std::vector<std::string>{"", "CP932", "GBK", "UTF-8"}
                : std::vector<std::string>{"", "CP932", "GBK", "GB18030", "BIG5", "UTF-8"};
        if(std::find(encodings.begin(), encodings.end(), result.encoding) == encodings.end())
            throw std::runtime_error("unsupported text encoding for " + engine + ": " + result.encoding);
        auto name = text.value("font_file", std::string{});
        if(!name.empty()) {
            std::replace(name.begin(), name.end(), '\\', '/');
            const auto relative = std::filesystem::u8path(name);
            if(relative.is_absolute() || name.find(':') != std::string::npos ||
               name.find('\0') != std::string::npos)
                throw std::runtime_error("font_file must be relative to the game");
            for(const auto& part : relative)
                if(part == "..") throw std::runtime_error("font_file escapes the game");
            result.font = std::filesystem::canonical(root / relative);
            for(const auto& part : result.font.lexically_relative(root))
                if(part == "..") throw std::runtime_error("font symlink escapes the game");
            auto extension = result.font.extension().string();
            std::transform(extension.begin(), extension.end(), extension.begin(),
                [](unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; });
            if((extension != ".ttf" && extension != ".otf") ||
               !std::filesystem::is_regular_file(result.font) ||
               std::filesystem::file_size(result.font) == 0 ||
               std::filesystem::file_size(result.font) > 32u * 1024u * 1024u)
                throw std::runtime_error("font_file must be a nonempty TTF/OTF file up to 32 MiB");
        }
        return result;
    } catch(const std::exception& error) {
        throw std::runtime_error(std::string("aether_config.json: ") + error.what());
    }
}
} // namespace aether::text
