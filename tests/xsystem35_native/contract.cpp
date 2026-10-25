#include "xsystem35_runtime_provider.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <thread>

namespace fs = std::filesystem;
static const engine_runtime_provider_v1_t *provider;
extern "C" engine_result_t
engine_register_runtime_provider(const engine_runtime_provider_v1_t *value) {
    provider = value;
    return ENGINE_RESULT_OK;
}
static void Require(bool condition, const char *message) {
    if(!condition)
        throw std::runtime_error(message);
}
static void MinimalGame(const fs::path &file) {
    // One synthetic ALD scenario page: Y 3,1 (wait), then jump back.
    // No game code, images, fonts or other copyrighted assets are required.
    std::vector<uint8_t> bytes(1024);
    bytes[0] = 1;
    bytes[3] = 2;
    bytes[6] = 2;
    bytes[256] = 1;
    bytes[257] = 2;
    // Reallocate an RGB world on every boot, as Rance5D does. Reopening must
    // not inspect the previous session's freed DIB/alpha plane.
    bytes[512] = 16;
    bytes[516] = 38;
    const uint8_t page[] = { 'S',  '3',  '5',  '0',  16,   0,    0,    0,
                             38,   0,    0,    0,    0,    0,    0,    0,
                             'W',  'W',  0x02, 0x80, 0x7f, 0x01, 0xe0, 0x7f,
                             0x58, 0x7f, 'Y',  0x43, 0x7f, 0x41, 0x7f, '@',
                             26,   0,    0,    0 };
    bytes[516] = sizeof(page);
    std::copy(std::begin(page), std::end(page), bytes.begin() + 528);
    std::ofstream stream(file, std::ios::binary);
    stream.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
}
static void MessageAIN(const fs::path &file, const std::string &text) {
    std::vector<uint8_t> bytes(32);
    bytes[0] = 'A';
    bytes[1] = 'I';
    bytes[2] = 'N';
    bytes[3] = 'I';
    bytes[8] = 'H';
    bytes[9] = 'E';
    bytes[10] = 'L';
    bytes[11] = '0';
    bytes[20] = 'M';
    bytes[21] = 'S';
    bytes[22] = 'G';
    bytes[23] = 'I';
    bytes[28] = 16;
    for(int i = 0; i < 16; i++) {
        bytes.insert(bytes.end(), text.begin(), text.end());
        bytes.push_back(0);
    }
    for(size_t i = 4; i < bytes.size(); i++)
        bytes[i] = uint8_t((bytes[i] >> 2) | (bytes[i] << 6));
    std::ofstream stream(file, std::ios::binary);
    stream.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
}
int main() {
    const auto cwd = fs::current_path();
    auto root =
        fs::temp_directory_path() /
        fs::u8path(
            "aether-system35-中文-" +
            std::to_string(
                std::chrono::steady_clock::now().time_since_epoch().count()));
    void *runtime = nullptr, *other = nullptr;
    try {
        Require(aetherkiri_xsystem35_register_runtime_provider() ==
                    ENGINE_RESULT_OK,
                "registration");
        Require(provider &&
                    std::string(provider->runtime_id_utf8) == "xsystem35",
                "runtime ID");
        fs::create_directories(root / "game");
        fs::create_directories(root / "saves");
        const auto game = (root / "game").u8string(),
                   saves = (root / "saves").u8string();
        Require(provider->probe(nullptr, game.c_str()) == 0,
                "empty directory matched");
        std::ofstream(root / "game/ADISK.dat") << "old system3";
        std::ofstream(root / "game/ACG.dat") << "old system3";
        Require(provider->probe(nullptr, game.c_str()) == 0,
                "legacy DAT game matched System35");
        const auto scenario = root / "game/MixedSa.AlD";
        std::ofstream(scenario) << "invalid ALD";
        Require(provider->probe(nullptr, game.c_str()) > 0,
                "mixed-case ALD not matched");
        std::ofstream(root / "game/ALICESTART.INI") << "System4";
        Require(provider->probe(nullptr, game.c_str()) == 0,
                "System4 took System35 route");
        fs::remove(root / "game/ALICESTART.INI");
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
        for(int i = 0; i < 3; i++) {
            Require(provider->open_game(runtime, game.c_str(), nullptr) !=
                        ENGINE_RESULT_OK,
                    "malformed archive opened");
            Require(std::string(provider->get_last_error(runtime))
                            .find("not an ALD") != std::string::npos,
                    "fatal archive error not contained");
        }
        MinimalGame(scenario);
        for(int i = 0; i < 3; i++) {
            const auto result =
                provider->open_game(runtime, game.c_str(), nullptr);
            Require(result == ENGINE_RESULT_OK,
                    provider->get_last_error(runtime));
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            Require(provider->tick(runtime, 16) == ENGINE_RESULT_OK,
                    provider->get_last_error(runtime));
            Require(fs::current_path() == cwd, "game changed process cwd");
            engine_frame_desc_t frame{};
            frame.struct_size = sizeof(frame);
            Require(provider->get_frame_desc(runtime, &frame) ==
                        ENGINE_RESULT_OK,
                    "frame description");
            Require(frame.width == 640 && frame.height == 480,
                    "wrong logical size");
            std::vector<uint8_t> rgba(size_t(frame.stride_bytes) *
                                      frame.height);
            Require(provider->read_frame_rgba(runtime, rgba.data(),
                                              rgba.size() - 1) ==
                        ENGINE_RESULT_INVALID_ARGUMENT,
                    "short frame buffer accepted");
            Require(provider->read_frame_rgba(runtime, rgba.data(),
                                              rgba.size()) == ENGINE_RESULT_OK,
                    "frame copy");
            Require(provider->pause(runtime) == ENGINE_RESULT_OK, "pause");
            Require(provider->resume(runtime) == ENGINE_RESULT_OK, "resume");
        }
        Require(provider->create(nullptr, &host, &desc, &other) ==
                    ENGINE_RESULT_OK,
                "second handle create");
        Require(provider->open_game(other, game.c_str(), nullptr) ==
                    ENGINE_RESULT_INVALID_STATE,
                "two VMs allowed concurrently");
        provider->destroy(other);
        other = nullptr;
        const auto check_encoding = [&](const std::string &text,
                                        const char *expected,
                                        const char *option = "auto") {
            MessageAIN(root / "game/System39.ain", text);
            engine_option_t encoding{};
            encoding.key_utf8 = "xsystem35_encoding";
            encoding.value_utf8 = option;
            Require(provider->set_option(runtime, &encoding) ==
                        ENGINE_RESULT_OK,
                    "encoding option");
            Require(provider->open_game(runtime, game.c_str(), nullptr) ==
                        ENGINE_RESULT_OK,
                    provider->get_last_error(runtime));
            char debug[4096]{};
            uint32_t written = 0;
            Require(provider->get_plugin_debug_info(runtime, debug,
                                                    sizeof(debug), &written) ==
                        ENGINE_RESULT_OK,
                    "debug encoding");
            Require(std::string(debug).find(expected) != std::string::npos,
                    "wrong auto/explicit legacy encoding");
        };
        check_encoding("\xd6\xd0\xce\xc4\xb2\xe2\xca\xd4\xd3\xce\xcf\xb7\xb5"
                       "\xc4\xba\xba\xbb\xaf\xb0\xe6\xb1\xbe",
                       "encoding=gbk");
        const std::string japanese =
            "\x83\x65\x83\x58\x83\x67\x83\x51\x81\x5b\x83\x80\x93\xfa\x96\x7b"
            "\x8c\xea\x82\xcc\x95\xb6\x8e\x9a";
        check_encoding(japanese, "encoding=sjis");
        check_encoding("中文 Unicode 测试游戏", "encoding=sjis");
        check_encoding(japanese, "encoding=gbk", "gbk");
        provider->destroy(runtime);
        runtime = nullptr;
        Require(fs::current_path() == cwd, "close changed process cwd");
        Require(!fs::exists(root / "game/Volume.sav"),
                "wrote settings into game assets");
        fs::remove_all(root);
        std::cout << "XSYSTEM35_CONTRACT_OK\n";
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
