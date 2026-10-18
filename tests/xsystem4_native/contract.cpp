#include "xsystem4_runtime_provider.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

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
int main() {
    fs::path root = fs::temp_directory_path() /
        ("aether-system4-contract-" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    void *runtime = nullptr;
    try {
        Require(aetherkiri_xsystem4_register_runtime_provider() ==
                    ENGINE_RESULT_OK,
                "Provider registration failed");
        Require(provider &&
                    std::string(provider->runtime_id_utf8) == "xsystem4",
                "Wrong runtime ID");
        fs::create_directories(root / "game");
        fs::create_directories(root / "saves");
        const std::string game = (root / "game").string(),
                          writable = (root / "saves").string();
        Require(provider->probe(nullptr, game.c_str()) == 0,
                "Empty folder must not match");
        std::ofstream(root / "game" / "GAME.AIN") << "invalid script";
        Require(provider->probe(nullptr, game.c_str()) == 0,
                "An AIN without its INI must not match");
        std::ofstream(root / "game" / "ALICESTART.INI")
            << "GameName = \"Contract\"\nCodeName = \"game.ain\"\nViewWidth = "
               "800\nViewHeight = 600\n";
        Require(provider->probe(nullptr, game.c_str()) > 0,
                "Case-insensitive System4 layout was not detected");
        engine_runtime_host_v1_t host{};
        host.struct_size = sizeof(host);
        host.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        engine_create_desc_t desc{};
        desc.struct_size = sizeof(desc);
        desc.api_version = ENGINE_API_VERSION;
        desc.writable_path_utf8 = writable.c_str();
        Require(provider->create(nullptr, &host, &desc, &runtime) ==
                    ENGINE_RESULT_OK,
                "Runtime creation failed");
        engine_option_t encoding{};
        encoding.key_utf8 = "xsystem4_encoding";
        encoding.value_utf8 = "invalid";
        Require(provider->set_option(runtime, &encoding) ==
                    ENGINE_RESULT_INVALID_ARGUMENT,
                "Invalid encoding accepted");
        uint32_t flags = 99;
        Require(provider->get_text_input_state(runtime, &flags) ==
                        ENGINE_RESULT_OK &&
                    flags == 0,
                "IME starts inactive");
        engine_input_event_t event{};
        event.struct_size = sizeof(event);
        event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
        event.unicode_codepoint = 0xd800;
        Require(provider->send_input(runtime, &event) ==
                    ENGINE_RESULT_INVALID_ARGUMENT,
                "A Unicode surrogate was accepted");
        for(int i = 0; i < 3; i++) {
            Require(provider->open_game(runtime, game.c_str(), nullptr) !=
                        ENGINE_RESULT_OK,
                    "Malformed AIN must fail");
            const std::string error = provider->get_last_error(runtime);
            Require(!error.empty() &&
                        error.find("Another System 4") == std::string::npos,
                    "Failed open retained the VM ownership lock");
        }
        provider->destroy(runtime);
        runtime = nullptr;
        fs::remove_all(root);
        std::cout << "XSYSTEM4_NATIVE_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        if(runtime)
            provider->destroy(runtime);
        fs::remove_all(root);
        std::cerr << "XSYSTEM4_NATIVE_CONTRACT_FAILED: " << error.what()
                  << '\n';
        return 1;
    }
}
