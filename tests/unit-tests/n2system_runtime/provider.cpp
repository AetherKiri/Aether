#include "n2system_runtime.h"
#include "engine_runtime_provider.h"
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <stdexcept>
#include <vector>
namespace {
const engine_runtime_provider_v1_t* provider;
void Require(bool condition, const char* message) { if(!condition) throw std::runtime_error(message); }
void Write(const std::filesystem::path& path, const std::string& value) { std::ofstream(path, std::ios::binary) << value; }
}
extern "C" engine_result_t engine_register_runtime_provider(const engine_runtime_provider_v1_t* value) {
    provider = value; return ENGINE_RESULT_OK;
}
int main() {
    auto root = std::filesystem::temp_directory_path() / ("aether-n2-contract-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(root);
    try {
        aetherkiri::n2system::RegisterRuntimeProvider();
        Require(provider != nullptr, "provider registration");
        const auto path = root.u8string();
        Require(provider->probe(nullptr, path.c_str()) == 0, "empty directory must not match");
        Write(root / "nss.npa", "unrelated"); Write(root / "system.npa", "unrelated");
        Require(provider->probe(nullptr, path.c_str()) == 0, "extensions alone must not match");
        const std::string magic("NPA\1\0\0\0", 7);
        Write(root / "nss.npa", magic); Write(root / "system.npa", magic);
        Require(provider->probe(nullptr, path.c_str()) > 0, "NPA pair magic detection");
        std::filesystem::remove(root / "nss.npa"); std::filesystem::remove(root / "system.npa");
        Write(root / "script.pak", "unrelated"); Write(root / "system.pak", "unrelated");
        Write(root / "sys_cn.ini", "width=800"); Write(root / "game_cn.ini", "Begin=menu.nps");
        Require(provider->probe(nullptr, path.c_str()) == 0, "legacy PAK extensions alone must not match");
        std::string legacyHeader(0x108, '\0'); legacyHeader[0] = 3; legacyHeader[0x104] = 100;
        Write(root / "script.pak", legacyHeader); Write(root / "system.pak", legacyHeader);
        Require(provider->probe(nullptr, path.c_str()) > 0, "legacy N2 PAK pair and configuration");
        std::filesystem::remove(root / "script.pak"); std::filesystem::remove(root / "system.pak");
        std::filesystem::remove(root / "sys_cn.ini"); std::filesystem::remove(root / "game_cn.ini");
        Write(root / "profiles.json", R"({"activeProfile":"x","profiles":{"x":{}}})");
        Require(provider->probe(nullptr, path.c_str()) == 0, "generic profiles must not match");
        Write(root / "profiles.json", R"({"activeProfile":"x","product.name":"Fixture","designResolution":"2x2","profiles":{"x":{}}})");
        Require(provider->probe(nullptr, path.c_str()) > 0, "intentional NitroSharp profile retains missing-asset diagnostics");
        std::filesystem::create_directories(root / "nss"); Write(root / "nss/boot.nss", "fixture");
        Require(provider->probe(nullptr, path.c_str()) > 0, "profile and loose scripts");
        Write(root / "profiles.json", R"({"activeProfile":null,"product.name":"Fixture","designResolution":"2x2"})");
        Require(provider->probe(nullptr, path.c_str()) > 0, "root profile without named selection");
        std::filesystem::remove(root / "profiles.json");
        Write(root / "AETHER-N2SYSTEM.JSON", "malformed explicit profile");
        Require(provider->probe(nullptr, path.c_str()) > 0, "explicit profile retains diagnostics");
        engine_runtime_host_v1_t host{}; host.struct_size = sizeof(host); host.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        engine_create_desc_t desc{}; desc.struct_size = sizeof(desc); desc.api_version = ENGINE_API_VERSION; desc.writable_path_utf8 = path.c_str();
        void* runtime = nullptr;
        Require(provider->create(nullptr, &host, &desc, &runtime) == ENGINE_RESULT_OK, "create");
        Require(std::async(std::launch::async, [&] { return provider->open_game(runtime, path.c_str(), nullptr); }).get() == ENGINE_RESULT_OK, "async open");
        Require(provider->open_game(runtime, path.c_str(), nullptr) == ENGINE_RESULT_INVALID_STATE, "double open");
        Require(provider->tick(runtime, 16) == ENGINE_RESULT_OK, "main-thread tick after worker open");
        engine_frame_desc_t frame{}; frame.struct_size = sizeof(frame);
        Require(provider->get_frame_desc(runtime, &frame) == ENGINE_RESULT_OK && frame.width == 2 && frame.stride_bytes == 8, "frame descriptor");
        std::vector<uint8_t> pixels(16);
        Require(provider->read_frame_rgba(runtime, pixels.data(), 15) == ENGINE_RESULT_INVALID_ARGUMENT, "frame capacity");
        Require(provider->read_frame_rgba(runtime, pixels.data(), pixels.size()) == ENGINE_RESULT_OK, "RGBA read");
        uint32_t rendered = 99; Require(provider->get_frame_rendered_flag(runtime, &rendered) == ENGINE_RESULT_OK && rendered == 0, "delivered frame flag");
        engine_input_event_t input{}; input.struct_size = sizeof(input); input.type = ENGINE_INPUT_EVENT_KEY_DOWN; input.key_code = '0';
        Require(provider->send_input(runtime, &input) == ENGINE_RESULT_OK, "key input");
        Require(provider->read_frame_rgba(runtime, pixels.data(), pixels.size()) == ENGINE_RESULT_OK && pixels[0] == 1 && pixels[1] == 39, "zero scancode");
        input.type = ENGINE_INPUT_EVENT_POINTER_DOWN; input.button = 1;
        Require(provider->send_input(runtime, &input) == ENGINE_RESULT_OK, "mouse input");
        Require(provider->read_frame_rgba(runtime, pixels.data(), pixels.size()) == ENGINE_RESULT_OK && pixels[0] == 4 && pixels[1] == 3, "right mouse mapping");
        input.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
        Require(provider->send_input(runtime, &input) == ENGINE_RESULT_NOT_SUPPORTED, "unsupported text");
        Require(provider->pause(runtime) == ENGINE_RESULT_OK, "pause");
        provider->get_frame_desc(runtime, &frame); const auto serial = frame.frame_serial;
        Require(provider->tick(runtime, 16) == ENGINE_RESULT_OK, "paused tick");
        provider->get_frame_desc(runtime, &frame); Require(frame.frame_serial == serial, "paused frame remains stable");
        Require(provider->resume(runtime) == ENGINE_RESULT_OK && provider->tick(runtime, 16) == ENGINE_RESULT_OK, "resume");
        provider->destroy(runtime);
        std::filesystem::remove_all(root);
        std::cout << "N2System provider contracts passed\n"; return 0;
    } catch(const std::exception& error) {
        std::filesystem::remove_all(root); std::cerr << error.what() << '\n'; return 1;
    }
}
