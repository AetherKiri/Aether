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
        // Translation patches may leave comments in the original encoding.
        // Resolve a non-ASCII script name using values, not comment text.
        const std::string sjis_comment =
            "\x82\xb1\x82\xcc\x83\x74\x83\x40\x83\x43\x83\x8b\x82\xcc\x8f\x89"
            "\x8a\xfa\x90\xdd\x92\xe8\x82\xcd\x8f\x91\x82\xab\x8a\xb7\x82\xa6"
            "\x82\xc8\x82\xa2\x82\xc5\x82\xad\x82\xbe\x82\xb3\x82\xa2\x81\x42";
        const std::string gbk_comment =
            "\xc7\xeb\xb2\xbb\xd2\xaa\xd0\xde\xb8\xc4\xd5\xe2\xb8\xf6\xd3\xce"
            "\xcf\xb7\xb5\xc4\xb3\xf5\xca\xbc\xbb\xaf\xc5\xe4\xd6\xc3\xce\xc4"
            "\xbc\xfe\xa1\xa3";
        const char *gbk_title =
            "\xd6\xd0\xce\xc4\xb2\xe2\xca\xd4\xd3\xce\xcf\xb7\x20\xba\xba\xbb"
            "\xaf\xb0\xe6\xb1\xbe\x20\xb2\xe2\xca\xd4\xc6\xf4\xb6\xaf\xb6\xc1"
            "\xc8\xa1\xce\xc4\xbc\xfe";
        const char *sjis_title =
            "\x83\x65\x83\x58\x83\x67\x83\x51\x81\x5b\x83\x80\x20\x93\xfa\x96"
            "\x7b\x8c\xea\x82\xcc\x93\xae\x8d\xec\x8a\x6d\x94\x46";
        const char *gbk_filename =
            "\xa5\xc6\xa5\xb9\xa5\xc8\xa3\xb0\xa3\xb2\x2e\x61\x69\x6e";
        const char *sjis_filename =
            "\x83\x65\x83\x58\x83\x67\x82\x4f\x82\x51\x2e\x61\x69\x6e";
        const auto check_encoding = [&](const char *folder, const char *title,
                                        const char *filename,
                                        const std::string &comment,
                                        const char *expected,
                                        const std::string &extra = "",
                                        const char *option = "auto") {
            const fs::path directory = root / folder;
            fs::create_directories(directory);
            std::ofstream(directory / fs::u8path(u8"テスト０２.ain"),
                          std::ios::binary)
                << "invalid script";
            std::ofstream config(directory / "AliceStart.ini",
                                 std::ios::binary);
            for(int i = 0; i < 8; i++)
                config << "  ; " << comment << "\r\n\t// " << comment << "\r\n";
            config << extra << "GameName = \"" << title << "\"\r\nCodeName = \""
                   << filename << "\"\r\n";
            config.close();
            encoding.value_utf8 = option;
            Require(provider->set_option(runtime, &encoding) ==
                        ENGINE_RESULT_OK,
                    "Valid encoding option rejected");
            Require(provider->open_game(runtime, directory.string().c_str(),
                                        nullptr) != ENGINE_RESULT_OK,
                    "Malformed encoded AIN must fail");
            const std::string error = provider->get_last_error(runtime);
            Require(
                error.find("Unrecognized or invalid AIN format") !=
                    std::string::npos,
                (std::string(folder) + ": wrong script path encoding").c_str());
            char info[4096]{};
            uint32_t written = 0;
            Require(provider->get_plugin_debug_info(runtime, info, sizeof(info),
                                                    &written) ==
                        ENGINE_RESULT_OK,
                    "Runtime debug info unavailable");
            Require(std::string(info).find(expected) != std::string::npos,
                    (std::string(folder) + ": wrong runtime text encoding")
                        .c_str());
        };
        check_encoding("gbk-values-sjis-comments", gbk_title, gbk_filename,
                       sjis_comment, "encoding=gbk");
        check_encoding("sjis-values-gbk-comments", sjis_title, sjis_filename,
                       gbk_comment, "encoding=sjis");
        check_encoding("pure-gbk", gbk_title, gbk_filename, gbk_comment,
                       "encoding=gbk");
        check_encoding("pure-sjis", sjis_title, sjis_filename, sjis_comment,
                       "encoding=sjis");
        check_encoding("ascii-title", "Contract", sjis_filename, "",
                       "encoding=sjis");
        std::string original_labels;
        for(int i = 0; i < 8; i++)
            original_labels += sjis_title;
        check_encoding("chinese-title-priority", gbk_title, gbk_filename,
                       sjis_comment, "encoding=gbk",
                       "BootName = \"" + original_labels + "\"\r\n");
        check_encoding("comment-markers-in-title",
                       (std::string("; // ") + gbk_title).c_str(), gbk_filename,
                       sjis_comment, "encoding=gbk",
                       "BootName = \"" + original_labels + "\"\r\n");
        check_encoding("sjis-inline-gbk-comments", sjis_title, sjis_filename,
                       "", "encoding=sjis",
                       "ViewWidth = 800 ; " + gbk_comment + "\r\n" +
                           "ViewHeight = 600 // " + gbk_comment + "\r\n");
        check_encoding("explicit-sjis", gbk_title, sjis_filename, gbk_comment,
                       "encoding=sjis", "", "sjis");
        check_encoding("explicit-gbk", sjis_title, gbk_filename, sjis_comment,
                       "encoding=gbk", "", "gbk");
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
