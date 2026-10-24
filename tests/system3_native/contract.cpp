#include "system3_runtime_provider.h"
#include "embedded_symbols.h"
#include "fileio.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
static const engine_runtime_provider_v1_t *provider;
extern "C" engine_result_t
engine_register_runtime_provider(const engine_runtime_provider_v1_t *value) {
    provider = value;
    return ENGINE_RESULT_OK;
}
static void Require(bool value, const char *message) {
    if(!value)
        throw std::runtime_error(message);
}
static void MinimalGame(const fs::path &file) {
    // A synthetic DRI archive: one UTF-8 text page, A (wait for input), loop.
    std::vector<uint8_t> data(768);
    data[0] = 2;
    data[2] = 3;
    data[4] = 4;
    data[256] = 1;
    data[257] = 1;
    const std::string page =
        std::string("\x02\x00", 2) + "'中文测试'A@\x02\x00";
    std::copy(page.begin(), page.end(), data.begin() + 512);
    std::ofstream output(file, std::ios::binary);
    output.write(reinterpret_cast<const char *>(data.data()), data.size());
}
static engine_frame_desc_t Frame(void *runtime) {
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    Require(provider->get_frame_desc(runtime, &frame) == ENGINE_RESULT_OK,
            "describe frame");
    return frame;
}
static void Set(void *runtime, const char *key, const char *value) {
    engine_option_t option{};
    option.key_utf8 = key;
    option.value_utf8 = value;
    Require(provider->set_option(runtime, &option) == ENGINE_RESULT_OK,
            "set option");
}
int main() {
    const auto cwd = fs::current_path();
    const auto root =
        fs::temp_directory_path() /
        fs::u8path(
            "aether-system3-中文-" +
            std::to_string(
                std::chrono::steady_clock::now().time_since_epoch().count()));
    void *runtime = nullptr, *other = nullptr;
    try {
        Require(aetherkiri_system3_register_runtime_provider() ==
                    ENGINE_RESULT_OK,
                "register");
        Require(provider && std::string(provider->runtime_id_utf8) == "system3",
                "provider ID");
        fs::create_directories(root / "game");
        fs::create_directories(root / "writable");
        const auto game = (root / "game").u8string(),
                   saves = (root / "writable").u8string();
        std::ofstream(root / "game/aDiSk.DaT") << "bad archive";
        Require(provider->probe(nullptr, game.c_str()) == 0,
                "DAT alone is ambiguous");
        std::ofstream(root / "game/aCg.Dat") << "graphics";
        Require(provider->probe(nullptr, game.c_str()) > 0,
                "mixed case DAT detection");
        for(const char *marker : { "ALICESTART.INI", "RanceSA.ALD" }) {
            std::ofstream(root / "game" / marker) << "newer runtime";
            Require(provider->probe(nullptr, game.c_str()) == 0,
                    "System4/35 exclusion");
            fs::remove(root / "game" / marker);
        }
        std::ofstream(root / "game/SyStEm3.InI")
            << "[config]\ngame=system3_generic\nencoding=utf8\n";
        engine_runtime_host_v1_t host{};
        host.struct_size = sizeof(host);
        host.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        engine_create_desc_t desc{};
        desc.struct_size = sizeof(desc);
        desc.api_version = ENGINE_API_VERSION;
        desc.writable_path_utf8 = saves.c_str();
        Require(provider->create(nullptr, &host, &desc, &runtime) ==
                    ENGINE_RESULT_OK,
                "create");
        Set(runtime, "default_font", SYSTEM3_TEST_FONT);
        for(int i = 0; i < 3; i++)
            Require(provider->open_game(runtime, game.c_str(), nullptr) !=
                        ENGINE_RESULT_OK,
                    "invalid archive contained without process exit");
        MinimalGame(root / "game/aDiSk.DaT");
        std::ofstream(root / "game/SyStEm3.InI")
            << "[config]\ngame=unknown_translation\n";
        Require(provider->open_game(runtime, game.c_str(), nullptr) !=
                    ENGINE_RESULT_OK,
                "unknown game id contained");
        std::ofstream(root / "game/SyStEm3.InI")
            << "[config]\ngame=system3_generic\nencoding=utf8\nsavedir=../"
               "outside\n";
        Set(runtime, "default_font", "/missing/aether-system3-font.ttf");
        Require(provider->open_game(runtime, game.c_str(), nullptr) !=
                    ENGINE_RESULT_OK,
                "font failure contained");
        Set(runtime, "default_font", SYSTEM3_TEST_FONT);
        std::ofstream(root / "game/ASLEEP_A.DAT") << "original save";
        for(int i = 0; i < 3; i++) {
            Require(provider->open_game(runtime, game.c_str(), nullptr) ==
                        ENGINE_RESULT_OK,
                    provider->get_last_error(runtime));
            auto frame = Frame(runtime);
            Require(frame.width == 640 && frame.height == 400 &&
                        frame.stride_bytes == 2560,
                    "native frame dimensions");
            std::vector<uint8_t> pixels(frame.stride_bytes * frame.height);
            Require(provider->read_frame_rgba(runtime, pixels.data(),
                                              pixels.size() - 1) ==
                        ENGINE_RESULT_INVALID_ARGUMENT,
                    "short read rejected");
            Require(provider->read_frame_rgba(runtime, pixels.data(),
                                              pixels.size()) ==
                        ENGINE_RESULT_OK,
                    "RGBA read");
            Require(provider->pause(runtime) == ENGINE_RESULT_OK, "pause");
            std::this_thread::sleep_for(std::chrono::milliseconds(80));
            auto paused = Frame(runtime).frame_serial;
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            Require(Frame(runtime).frame_serial == paused,
                    "VM continues while paused");
            auto original = FILEIO::open_save(1, FILEIO_READ_BINARY);
            Require(original &&
                        original->read_string(13) ==
                            (i ? "isolated save" : "original save"),
                    "imported/isolated save lookup");
            original.reset();
            auto output = FILEIO::open_save(1, FILEIO_WRITE_BINARY);
            Require(output && output->write("isolated save", 13),
                    "isolated save write");
            output.reset();
            Require(fs::file_size(root / "game/ASLEEP_A.DAT") == 13,
                    "original save changed");
            std::ifstream imported(root / "game/ASLEEP_A.DAT");
            std::string text;
            std::getline(imported, text);
            Require(text == "original save", "original overwritten");
            Require(provider->resume(runtime) == ENGINE_RESULT_OK, "resume");
            std::this_thread::sleep_for(std::chrono::milliseconds(80));
            Require(Frame(runtime).frame_serial > paused, "VM did not resume");
            engine_input_event_t input{};
            input.struct_size = sizeof(input);
            input.type = ENGINE_INPUT_EVENT_POINTER_DOWN;
            input.x = 320;
            input.y = 350;
            Require(provider->send_input(runtime, &input) == ENGINE_RESULT_OK,
                    "pointer down");
            input.type = ENGINE_INPUT_EVENT_POINTER_UP;
            Require(provider->send_input(runtime, &input) == ENGINE_RESULT_OK,
                    "pointer up");
            input.type = ENGINE_INPUT_EVENT_KEY_DOWN;
            input.key_code = 13;
            Require(provider->send_input(runtime, &input) == ENGINE_RESULT_OK,
                    "keyboard input");
            input.type = ENGINE_INPUT_EVENT_KEY_UP;
            Require(provider->send_input(runtime, &input) == ENGINE_RESULT_OK,
                    "keyboard release");
            Require(fs::current_path() == cwd, "process cwd changed");
        }
        Require(provider->create(nullptr, &host, &desc, &other) ==
                    ENGINE_RESULT_OK,
                "create second VM");
        Require(provider->open_game(other, game.c_str(), nullptr) ==
                    ENGINE_RESULT_INVALID_STATE,
                "concurrent VM accepted");
        provider->destroy(other);
        other = nullptr;
        provider->destroy(runtime);
        runtime = nullptr;
        Require(fs::current_path() == cwd, "cwd changed after teardown");
        fs::remove_all(root);
        std::cout << "SYSTEM3_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        if(other)
            provider->destroy(other);
        if(runtime)
            provider->destroy(runtime);
        fs::remove_all(root);
        std::cerr << error.what() << '\n';
        return 1;
    }
}
