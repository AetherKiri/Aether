#include "xsystem35_runtime_provider.h"
extern "C" {
#include "texthook.h"
}
#include <SDL.h>
#include <SDL_image.h>
#include <SDL_mixer.h>
#include <nlohmann/json.hpp>
using Json = nlohmann::json;
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>
namespace fs = std::filesystem;
void *player;
const engine_runtime_provider_v1_t *provider;
extern "C" engine_result_t
engine_register_runtime_provider(const engine_runtime_provider_v1_t *value) {
    provider = value;
    return ENGINE_RESULT_OK;
}
fs::path game, output;
std::string font;
uint64_t sequence;
void Check(engine_result_t result) {
    if(result == ENGINE_RESULT_OK)
        return;
    const char *text = provider ? provider->get_last_error(player)
                                : "No runtime provider registered";
    throw std::runtime_error(std::string(text ? text : "") +
                             " (result=" + std::to_string(result) + ")");
}
void Open() {
    const std::string writable = (output / "saves").string(),
                      cache = (output / "cache").string();
    fs::create_directories(writable);
    fs::create_directories(cache);
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    desc.api_version = ENGINE_API_VERSION;
    desc.writable_path_utf8 = writable.c_str();
    desc.cache_path_utf8 = cache.c_str();
    engine_runtime_host_v1_t host{};
    host.struct_size = sizeof(host);
    host.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
    host.log = [](void *, uint32_t, const char *, const char *message) {
        std::cerr << message << '\n';
    };
    Check(provider->create(nullptr, &host, &desc, &player));
    engine_option_t f{};
    f.key_utf8 = "default_font";
    f.value_utf8 = font.c_str();
    Check(provider->set_option(player, &f));
    Check(provider->open_game(player, game.string().c_str(), nullptr));
}
void Atomic(const fs::path &file, const std::string &value) {
    auto temporary = file;
    temporary += ".tmp";
    {
        std::ofstream stream(temporary);
        stream << value;
    }
    fs::rename(temporary, file);
}
void Status(const char *error = nullptr) {
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    provider->get_frame_desc(player, &frame);
    Json json;
    json["ack"] = double(sequence);
    json["width"] = frame.width;
    json["height"] = frame.height;
    json["serial"] = double(frame.frame_serial);
    json["error"] = error ? error : "";
    char debug[4096]{};
    uint32_t written = 0;
    provider->get_plugin_debug_info(player, debug, sizeof(debug), &written);
    json["runtime"] = debug;
    json["music_playing"] = Mix_PlayingMusic() != 0;
    json["sound_channels"] = Mix_Playing(-1);
    Atomic(output / "status.json", json.dump());
}
void Capture(const std::string &name) {
    if(name.empty() ||
       name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV"
                              "WXYZ0123456789-_") != std::string::npos)
        throw std::runtime_error("Invalid capture name");
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    Check(provider->get_frame_desc(player, &frame));
    std::vector<uint8_t> pixels(size_t(frame.stride_bytes) * frame.height);
    Check(provider->read_frame_rgba(player, pixels.data(), pixels.size()));
    SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormatFrom(
        pixels.data(), frame.width, frame.height, 32, frame.stride_bytes,
        SDL_PIXELFORMAT_RGBA32);
    if(!surface)
        throw std::runtime_error(SDL_GetError());
    const int result =
        IMG_SavePNG(surface, (output / (name + ".png")).string().c_str());
    SDL_FreeSurface(surface);
    if(result)
        throw std::runtime_error(IMG_GetError());
}
double Number(const Json &json, const char *key, double fallback = 0) {
    return json.contains(key) && json[key].is_number() ? json[key].get<double>()
                                                       : fallback;
}
std::string String(const Json &json, const char *key,
                   const char *fallback = "") {
    return json.contains(key) && json[key].is_string()
        ? json[key].get<std::string>()
        : fallback;
}
bool Command(const Json &json) {
    const std::string action = String(json, "action");
    if(action == "quit")
        return false;
    if(action == "capture")
        Capture(String(json, "name", "frame"));
    else if(action == "pause")
        Check(provider->pause(player));
    else if(action == "resume")
        Check(provider->resume(player));
    else if(action == "reopen") {
        provider->destroy(player);
        player = nullptr;
        Open();
    } else if(action == "click" || action == "key") {
        engine_input_event_t event{};
        event.struct_size = sizeof(event);
        event.x = Number(json, "x");
        event.y = Number(json, "y");
        event.button = int(Number(json, "button", 0));
        event.key_code = int(Number(json, "key", 13));
        const int count =
            std::max(1, std::min(50, int(Number(json, "count", 1))));
        for(int i = 0; i < count; i++) {
            event.type = action == "click" ? ENGINE_INPUT_EVENT_POINTER_DOWN
                                           : ENGINE_INPUT_EVENT_KEY_DOWN;
            Check(provider->send_input(player, &event));
            std::this_thread::sleep_for(std::chrono::milliseconds(
                std::clamp(int(Number(json, "hold_ms", 100)), 0, 10000)));
            event.type = action == "click" ? ENGINE_INPUT_EVENT_POINTER_UP
                                           : ENGINE_INPUT_EVENT_KEY_UP;
            Check(provider->send_input(player, &event));
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    }
    return true;
}
int main(int argc, char **argv) {
    if(argc != 4) {
        std::cerr << "Usage: probe GAME OUTPUT FONT\n";
        return 2;
    }
    game = fs::absolute(argv[1]);
    output = fs::absolute(argv[2]);
    font = fs::absolute(argv[3]).string();
    fs::create_directories(output);
    try {
        Check(aetherkiri_xsystem35_register_runtime_provider());
        texthook_set_mode(TEXTHOOK_PRINT);
        Open();
        std::cout << "XSYSTEM35_PROBE_READY\n" << std::flush;
        Capture("startup");
        Status();
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::minutes(20);
        while(std::chrono::steady_clock::now() < deadline) {
            auto command = output / "command.json";
            if(fs::is_regular_file(command)) {
                std::ifstream file(command);
                std::stringstream text;
                text << file.rdbuf();
                Json json = Json::parse(text.str(), nullptr, false);
                if(!json.is_discarded()) {
                    const uint64_t seq = uint64_t(Number(json, "seq"));
                    if(seq > sequence) {
                        sequence = seq;
                        const bool keep_running = Command(json);
                        Status();
                        if(!keep_running)
                            break;
                    }
                }
            }
            Check(provider->tick(player, 16));
            std::this_thread::sleep_for(std::chrono::milliseconds(16));
        }
        provider->destroy(player);
        player = nullptr;
        std::cout << "XSYSTEM35_PROBE_OK\n";
        return 0;
    } catch(const std::exception &error) {
        Status(error.what());
        if(player)
            provider->destroy(player);
        std::cerr << "XSYSTEM35_PROBE_FAILED: " << error.what() << '\n';
        return 1;
    }
}
