#include "xsystem4_runtime_provider.h"
extern "C" {
#include "system4/ain.h"
#include "system4/instructions.h"
}
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace fs = std::filesystem;
using Bytes = std::vector<uint8_t>;
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

static void Int(Bytes &bytes, int32_t value) {
    for(int i = 0; i < 4; ++i)
        bytes.push_back(uint32_t(value) >> (8 * i));
}

static void Text(Bytes &bytes, const char *value) {
    while(*value)
        bytes.push_back(*value++);
}

static void Instruction(Bytes &bytes, enum opcode op, int32_t argument) {
    bytes.push_back(op & 0xff);
    bytes.push_back(op >> 8);
    Int(bytes, argument);
}

static void Fixture(const fs::path &game, int exit_code, bool returns,
                    bool fatal) {
    Bytes code;
    Instruction(code, FUNC, 0);
    Instruction(code, PUSH, exit_code);
    if(fatal)
        Instruction(code, CALLSYS, 0xffff); // A genuine VM error.
    else if(returns) {
        code.push_back(RETURN);
        code.push_back(0);
    } else
        Instruction(code, CALLSYS, SYS_EXIT);

    Bytes bytes;
    Text(bytes, "VERS");
    Int(bytes, 6);
    Text(bytes, "CODE");
    Int(bytes, code.size());
    bytes.insert(bytes.end(), code.begin(), code.end());
    Text(bytes, "FUNC");
    Int(bytes, 1);
    Int(bytes, 6); // main starts after its FUNC instruction.
    Text(bytes, "main");
    bytes.push_back(0);
    Int(bytes, 0); // is_label
    Int(bytes, AIN_INT);
    Int(bytes, -1); // return struct
    Int(bytes, 0); // args
    Int(bytes, 0); // variables
    Int(bytes, 0); // crc
    Text(bytes, "MAIN");
    Int(bytes, 0);
    for(const char *tag :
        { "GLOB", "GSET", "STRT", "MSG0", "HLL0", "SWI0", "STR0", "FNAM" }) {
        Text(bytes, tag);
        Int(bytes, 0);
    }
    Text(bytes, "MSGF");
    Int(bytes, -1);
    ain_decrypt(bytes.data(), bytes.size()); // Symmetric AIN encryption.
    std::ofstream output(game / "lifecycle.ain", std::ios::binary);
    output.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    Require(bool(output), "Could not write the synthetic script");
}

int main() {
    const fs::path root = fs::temp_directory_path() /
        ("aether-system4-lifecycle-" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    void *runtime = nullptr;
    try {
        Require(aetherkiri_xsystem4_register_runtime_provider() ==
                    ENGINE_RESULT_OK,
                "Provider registration failed");
        const fs::path game = root / "game";
        fs::create_directories(game);
        std::ofstream(game / "System40.ini")
            << "GameName = \"Lifecycle\"\nCodeName = \"lifecycle.ain\"\n"
               "ViewWidth = 64\nViewHeight = 64\n";
        const std::string saves = (root / "saves").string();
        engine_create_desc_t desc{};
        desc.struct_size = sizeof(desc);
        desc.api_version = ENGINE_API_VERSION;
        desc.writable_path_utf8 = saves.c_str();
        engine_runtime_host_v1_t host{};
        host.struct_size = sizeof(host);
        host.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        Require(provider->create(nullptr, &host, &desc, &runtime) ==
                    ENGINE_RESULT_OK,
                "Runtime creation failed");
        const auto check = [&](int code, bool returns, bool fatal) {
            Fixture(game, code, returns, fatal);
            Require(provider->open_game(runtime, game.string().c_str(),
                                        nullptr) != ENGINE_RESULT_OK,
                    "The fixture must exit before producing a frame");
            const std::string error = provider->get_last_error(runtime);
            const bool normal = error.find("runtime requested termination") !=
                std::string::npos;
            Require(normal == !fatal,
                    (std::string("Incorrect exit classification: ") + error)
                        .c_str());
            Require(!fatal ||
                        error.find("Unimplemented syscall") !=
                            std::string::npos,
                    "The original VM failure diagnostic was lost");
            Require(error.find("Another System 4") == std::string::npos,
                    "Exit retained the VM ownership lock");
            Require(provider->tick(runtime, 16) != ENGINE_RESULT_OK,
                    "An exited session must not keep ticking");
            Require(std::string(provider->get_last_error(runtime)) == error,
                    "Tick replaced the original exit diagnostic");
        };
        for(int code : { 0, 1, 7, -1 }) {
            check(code, false, false);
            check(code, false,
                  true); // Error after a clean exit must stay fatal.
            check(code, true, false); // Returning from main is also completion.
        }
        provider->destroy(runtime);
        runtime = nullptr;
        fs::remove_all(root);
        std::cout << "XSYSTEM4_LIFECYCLE_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        if(runtime)
            provider->destroy(runtime);
        fs::remove_all(root);
        std::cerr << "XSYSTEM4_LIFECYCLE_CONTRACT_FAILED: " << error.what()
                  << '\n';
        return 1;
    }
}
