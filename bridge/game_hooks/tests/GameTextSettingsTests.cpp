#include "AetherGameHooks.h"
#include "AetherGameTextSettings.h"
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>

namespace fs = std::filesystem;
using aether::hooks::GameHooks;
using aether::text::GameTextSettings;
namespace {
struct Fixture {
    fs::path root = fs::temp_directory_path() / ("aether-text-test-" + std::to_string(std::random_device{}()));
    Fixture() { fs::create_directories(root); }
    ~Fixture() { std::error_code error; fs::remove_all(root, error); }
    void Write(const std::string& name, const std::string& data) {
        const auto path = root / fs::u8path(name);
        fs::create_directories(path.parent_path());
        std::ofstream(path, std::ios::binary) << data;
    }
    void Config(const std::string& encoding, const std::string& font = "") {
        Write("aether_config.json", "{\"rendering\":{\"output_resolution\":\"4k\"},\"text\":{\"encoding\":\"" + encoding + "\",\"font_file\":\"" + font + "\"}}");
    }
};
void Check(bool condition, const char* message) {
    if(!condition) throw std::runtime_error(message);
}
template<class Action> void Reject(Action action) {
    try { action(); } catch(const std::exception& error) {
        Check(std::string(error.what()).find("aether_config.json") != std::string::npos,
              "configuration errors must identify their source");
        return;
    }
    throw std::runtime_error("invalid configuration was accepted");
}
}
int main() {
    try {
        Fixture first, second;
        first.Write("字体/自定义.OTF", "font bytes validated by the renderer");
        first.Write("patch.ttf", "patch font");
        const auto selected_font = fs::canonical(first.root / fs::u8path("字体/自定义.OTF"));
        GameHooks hooks;
        for(const std::string engine : {"onscripter", "yuris", "systemc", "rfvp", "bgi", "advhd", "escude", "softpal", "catsystem2", "entisgls"}) {
            fs::remove(first.root / "aether_config.json");
            Check(GameTextSettings::Load(first.root, engine).font.empty(), "missing config must inherit");
            for(const std::string encoding : {"", "CP932", "GBK", "GB18030", "BIG5", "UTF-8"}) {
                first.Config(encoding, "字体/自定义.OTF");
                const bool supported = engine == "entisgls" ? encoding.empty()
                    : (engine == "onscripter" || engine == "rfvp") ? encoding != "BIG5" && encoding != "GB18030" : true;
                if(!supported) { Reject([&] { GameTextSettings::Load(first.root, engine); }); continue; }
                const auto settings = GameTextSettings::Load(first.root, engine);
                Check(settings.encoding == encoding && settings.font == selected_font, "engine capability/Unicode font path mismatch");
                hooks.Load(first.root, engine);
                Check(hooks.Encoding() == encoding && hooks.Font() == selected_font, "settings must reach hooks without a Lua script");
                Check(!hooks.Active() && hooks.Files().empty(), "JSON settings must not activate a resource overlay");
                hooks.Load(second.root, engine);
                Check(hooks.Encoding().empty() && hooks.Font().empty(), "settings leaked between games");
            }
        }
        first.Write("aether.lua", "aether.set_encoding('gbk'); aether.set_font('patch.ttf'); aether.add_file('dialog.txt', 'translated')");
        first.Config("UTF-8", "字体/自定义.OTF");
        hooks.Load(first.root, "bgi");
        Check(hooks.Active() && hooks.Find("dialog.txt"), "user settings removed the patch's resources");
        Check(hooks.Encoding() == "UTF-8" && hooks.Font() == selected_font, "explicit user settings must beat patch defaults");
        first.Config("");
        hooks.Load(first.root, "bgi");
        Check(hooks.Encoding() == "GBK" && hooks.Font() == fs::canonical(first.root / "patch.ttf"), "reset must restore patch defaults");
        fs::create_directories(first.root / "system");
        first.Config("BIG5", "字体/自定义.OTF");
        hooks.Load(first.root / "system", "yuris", first.root);
        Check(hooks.Encoding() == "BIG5" && hooks.Font() == selected_font, "YU-RIS must read settings from its import root");
        for(const std::string invalid : {"{broken", "[]", "{\"text\":[]}", "{\"text\":{\"encoding\":12}}", "{\"text\":{\"font_file\":null}}"}) {
            first.Write("aether_config.json", invalid);
            Reject([&] { hooks.Load(first.root, "bgi"); });
            Check(hooks.Font().empty() && hooks.Encoding().empty() && hooks.Files().empty(), "failed load retained prior game state");
        }
        for(const std::string invalid : {"../patch.ttf", "/tmp/font.ttf", "C:/font.ttf", "missing.ttf", "aether.lua"}) {
            first.Config("", invalid);
            Reject([&] { GameTextSettings::Load(first.root, "bgi"); });
        }
        second.Write("outside.ttf", "font");
        fs::create_directory_symlink(second.root, first.root / "outside");
        first.Config("", "outside/outside.ttf");
        Reject([&] { GameTextSettings::Load(first.root, "bgi"); });
        first.Config("ISO-8859-1");
        Reject([&] { GameTextSettings::Load(first.root, "bgi"); });
        Check(GameTextSettings::Load(first.root, "kirikiri").encoding.empty(), "unselected engines must retain their existing behavior");
        std::cout << "GAME_TEXT_SETTINGS_OK: 10 engines, inheritance, patch priority, isolation, malformed data and paths\n";
        return 0;
    } catch(const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
