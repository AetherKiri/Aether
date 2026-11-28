#include "mod_manager.h"
#include <nlohmann/json.hpp>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
namespace fs = std::filesystem;
using Json = nlohmann::json;
void expect(bool result, const char *message) { if (!result) throw std::runtime_error(message); }
void put(const fs::path &path, const std::string &text) {
    fs::create_directories(path.parent_path()); std::ofstream(path, std::ios::binary) << text;
}
std::string get(const fs::path &path) {
    std::ifstream file(path, std::ios::binary); return {std::istreambuf_iterator<char>(file), {}};
}
Json run(const fs::path &root, const char *action, const std::string &source = "") {
    return Json::parse(aether::xsystem::mod_operation(root.u8string(), action, source));
}
void zip(const fs::path &path, const std::string &name, const std::string &text) {
    // Store-only ZIP fixture, independent of the archive reader under test.
    uint32_t crc = ~uint32_t(0);
    for (unsigned char byte : text) {
        crc ^= byte;
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1));
    }
    crc = ~crc;
    std::string bytes;
    auto le = [&](uint32_t value, int count) { for (int i = 0; i < count; ++i) bytes += char(value >> (8 * i)); };
    le(0x04034b50, 4); le(20, 2); le(0, 2); le(0, 2); le(0, 4);
    le(crc, 4); le(uint32_t(text.size()), 4); le(uint32_t(text.size()), 4);
    le(uint32_t(name.size()), 2); le(0, 2); bytes += name; bytes += text;
    const auto offset = uint32_t(bytes.size());
    le(0x02014b50, 4); le(20, 2); le(20, 2); le(0, 2); le(0, 2); le(0, 4);
    le(crc, 4); le(uint32_t(text.size()), 4); le(uint32_t(text.size()), 4);
    le(uint32_t(name.size()), 2); le(0, 2); le(0, 2); le(0, 2); le(0, 2); le(0, 4); le(0, 4); bytes += name;
    const auto size = uint32_t(bytes.size()) - offset;
    le(0x06054b50, 4); le(0, 2); le(0, 2); le(1, 2); le(1, 2); le(size, 4); le(offset, 4); le(0, 2);
    put(path, bytes);
}
int main() {
    auto temp = fs::temp_directory_path() / ("aether-mod-test-" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        auto game = temp / "game", a = temp / "first", b = temp / "second";
        put(game / "Game.ain", "original"); put(game / "SaveData/Save01.asd", "user-save");
        put(game / "System40.ini", "SaveFolder = \"progress\"\n");
        put(game / "progress/state.dat", "custom-save");
        put(a / "game.ain", "first"); put(a / "extra.afa", "added");
        put(a / "SaveData/Save01.asd", "do-not-install");
        put(a / "progress/state.dat", "do-not-install");
        put(b / "GAME.ain", "second");
        auto installed = run(game, "install", a.u8string());
        expect(installed["ok"], installed.dump().c_str());
        auto first = installed["installed_id"].get<std::string>();
        expect(get(game / "Game.ain") == "first", "case-insensitive replacement");
        expect(get(game / "SaveData/Save01.asd") == "user-save", "save preserved");
        expect(get(game / "progress/state.dat") == "custom-save", "INI-configured save folder preserved");
        auto second_result = run(game, "install", b.u8string());
        expect(second_result["ok"], "overlapping mod installed");
        auto second = second_result["installed_id"].get<std::string>();
        expect(run(game, "uninstall", first)["ok"], "remove lower mod");
        expect(get(game / "Game.ain") == "second", "higher overlay survives lower removal");
        expect(!fs::exists(game / "extra.afa"), "added file removed");
        expect(run(game, "uninstall", second)["ok"], "remove final mod");
        expect(get(game / "Game.ain") == "original", "original restored after arbitrary removal");
        expect(run(game, "list")["mods"].empty(), "manifest empty");
        auto lower = run(game, "install", a.u8string());
        auto upper = run(game, "install", b.u8string());
        expect(run(game, "uninstall", upper["installed_id"])["ok"], "remove upper mod first");
        expect(get(game / "Game.ain") == "first", "lower mod is restored");
        expect(run(game, "uninstall", lower["installed_id"])["ok"], "remove remaining lower mod");
        expect(get(game / "Game.ain") == "original", "original restored after upper removal");
        auto resources = temp / "resources";
        put(resources / "data/face.png", "portrait");
        auto resource_result = run(game, "install", resources.u8string());
        expect(resource_result["ok"] && get(game / "data/face.png") == "portrait", "resource subdirectory preserved");
        expect(run(game, "uninstall", resource_result["installed_id"])["ok"], "resource uninstall");
        expect(!fs::exists(game / "data/face.png"), "resource removed from correct directory");
        auto direct = run(game, "install", (a / "game.ain").u8string());
        expect(direct["ok"] && get(game / "Game.ain") == "first", "single asset install");
        expect(run(game, "uninstall", direct["installed_id"])["ok"], "single asset restore");
        expect(run(game, "install", game.u8string())["error"] == "source_overlaps_game", "reject recursive source");
        zip(temp / "wrapped.zip", "Wrapper/Game.ain", "zipped");
        auto archived = run(game, "install", (temp / "wrapped.zip").u8string());
        expect(archived["ok"] && get(game / "Game.ain") == "zipped", "archive wrapper");
        expect(run(game, "uninstall", archived["installed_id"])["ok"], "archive restore");
        zip(temp / "bad.zip", "../escaped.ain", "unsafe");
        expect(!run(game, "install", (temp / "bad.zip").u8string())["ok"], "reject traversal");
        expect(!fs::exists(temp / "escaped.ain"), "traversal did not write outside game");
        auto conflict = temp / "conflict";
        put(conflict / "Game.ain", "bad"); put(conflict / "folder.afa", "bad");
        fs::create_directory(game / "folder.afa");
        expect(!run(game, "install", conflict.u8string())["ok"], "reject directory collision");
        expect(get(game / "Game.ain") == "original", "failed install preserved original");
#ifndef _WIN32
        auto linked = temp / "linked"; fs::create_directory(linked);
        fs::create_symlink(game / "Game.ain", linked / "Game.ain");
        expect(!run(game, "install", linked.u8string())["ok"], "reject source symlink");
#endif
        // Simulate interruption after files changed but before manifest commit.
        auto store = game / ".aether-mods";
        auto previous = Json::parse(get(store / "manifest.json"));
        put(store / "rollback/Game.ain", "original");
        put(game / "Game.ain", "interrupted");
        put(store / "pending.json", Json({{"previous", previous}, {"files", {{"Game.ain", true}}}}).dump());
        expect(run(game, "list")["ok"], "recover interrupted transaction");
        expect(get(game / "Game.ain") == "original", "recovery restores bytes");
        put(store / "manifest.json", "{invalid");
        expect(!run(game, "uninstall", "123")["ok"], "refuse corrupt journal");
        expect(get(game / "Game.ain") == "original", "corrupt manifest leaves assets alone");
        fs::remove_all(temp);
        std::cout << "MOD_INSTALL_RESTORE_OK\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\nFixture: " << temp << '\n';
        return 1;
    }
}
