#include "aether/game_detection.h"
#include "aether/native_host/runtime_session.h"
#include "engine_runtime_provider.h"
#include <algorithm>
#include <nlohmann/json.hpp>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace fs = std::filesystem;
using aether::native_host::RuntimeSession;

void Require(bool value, std::string message) {
    if (!value) throw std::runtime_error(std::move(message));
}

void Check(engine_handle_t handle, engine_result_t result) {
    if (result != ENGINE_RESULT_OK)
        throw std::runtime_error("engine result " + std::to_string(result) + ": " + engine_get_last_error(handle));
}

nlohmann::json Info(engine_handle_t handle) {
    char text[4096]{};
    uint32_t size = 0;
    Check(handle, engine_get_plugin_debug_info(handle, text, sizeof(text), &size));
    return nlohmann::json::parse(text);
}

std::string Position(const nlohmann::json &info) {
    return info.at("script").get<std::string>() + ":" + info.at("word").dump() + "/" + info.at("message").dump();
}

engine_frame_desc_t Frame(engine_handle_t handle, const fs::path &capture = {}) {
    engine_frame_desc_t frame{}; frame.struct_size = sizeof(frame);
    Check(handle, engine_get_frame_desc(handle, &frame));
    Require(frame.width && frame.height && frame.stride_bytes == frame.width*4 &&
        frame.pixel_format == ENGINE_PIXEL_FORMAT_RGBA8888, "Invalid native frame");
    std::vector<uint8_t> rgba(size_t(frame.stride_bytes)*frame.height);
    Check(handle, engine_read_frame_rgba(handle, rgba.data(), rgba.size()));
    if (!capture.empty()) {
        size_t colors = 0;
        std::ofstream image(capture, std::ios::binary);
        image << "P6\n" << frame.width << " " << frame.height << "\n255\n";
        for (size_t i = 0; i < rgba.size(); i += 4) {
            colors += (rgba[i] != rgba[0] || rgba[i+1] != rgba[1] || rgba[i+2] != rgba[2]);
            Require(rgba[i+3] == 255, "Non-opaque RGBA pixel");
            image.write(reinterpret_cast<const char *>(&rgba[i]), 3);
        }
        Require(image.good() && colors > 100, "Empty or solid display frame");
    }
    return frame;
}

void Key(engine_handle_t handle, int code) {
    engine_input_event_t e{}; e.struct_size = sizeof(e); e.key_code = code;
    e.type = ENGINE_INPUT_EVENT_KEY_DOWN;
    Check(handle, engine_send_input(handle, &e));
    e.type = ENGINE_INPUT_EVENT_KEY_UP;
    Check(handle, engine_send_input(handle, &e));
}

void Open(RuntimeSession &session, const fs::path &root, const fs::path &work, const fs::path &font, bool explicit_id) {
    engine_create_desc_t desc{}; desc.struct_size = sizeof(desc); desc.api_version = ENGINE_API_VERSION;
    desc.writable_path_utf8 = work.c_str(); desc.cache_path_utf8 = work.c_str();
    Check(nullptr, session.Create(desc));
    auto handle = session.handle();
    engine_option_t option{}; option.key_utf8 = "default_font"; option.value_utf8 = font.c_str();
    Check(handle, engine_set_option(handle, &option));
    if (explicit_id) {
        option.key_utf8 = "runtime"; option.value_utf8 = "systemnnn";
        Check(handle, engine_set_option(handle, &option));
    }
    Check(handle, engine_open_game_async(handle, root.c_str(), nullptr));
    uint32_t startup = ENGINE_STARTUP_STATE_RUNNING;
    for (int i = 0; i < 6000 && startup == ENGINE_STARTUP_STATE_RUNNING; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        Check(handle, engine_get_startup_state(handle, &startup));
    }
    Require(startup == ENGINE_STARTUP_STATE_SUCCEEDED, std::string("Startup failed: ") + engine_get_last_error(handle));
}

int main(int argc, char **argv) try {
    aether::native_host::RegisterProviders();
    Require(aether::native_host::SupportsRuntime("systemnnn"), "Native Host does not support SystemNNN");
    Require(aether::native_host::UseNativeSession("systemnnn", "Native Session", false) &&
        aether::native_host::UseNativeSession("systemnnn", "Godot Native", true) &&
        !aether::native_host::UseNativeSession("systemnnn", "Godot Native", false) &&
        !aether::native_host::UseNativeSession("systemnnn", "Godot", true) &&
        !aether::native_host::UseNativeSession("absent", "Native Session", true), "Native routing mismatch");
    if (argc == 1) {
        auto fixture = fs::temp_directory_path() / ("aether-systemnnn-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        fs::create_directories(fixture/"spt");
        std::ofstream(fixture/"novel.exe").close();
        Require(engine_probe_runtime_provider("systemnnn", fixture.c_str()) == 0, "An EXE alone is not a match");
        std::ofstream(fixture/"spt/sys.spt").close();
        Require(aether::game_detection::DetectGame((fixture/"novel.exe").string()).engine == "systemnnn" &&
            engine_probe_runtime_provider("systemnnn", fixture.c_str()) > 0, "Directory and EXE detection failed");
        fs::remove_all(fixture);
        return 0;
    }
    Require(argc == 4, "Usage: systemnnn-native-probe <disposable game copy> <font> <output directory>");
    const auto root = fs::canonical(argv[1]), font = fs::canonical(argv[2]), work = fs::absolute(argv[3]);
    fs::create_directories(work);
    RuntimeSession session;
    Require(aether::game_detection::DetectGame(root.string()).engine == "systemnnn", "Wrong runtime detected");
    Open(session, root, work, font, false);
    auto handle = session.handle();
    for (int i = 0; i < 70; ++i) Check(handle, engine_tick(handle, 40));
    auto frame = Frame(handle, work/"title.ppm");
    const auto title_info = Info(handle);
    Require(title_info.at("mode") == "title", title_info.dump());
    Check(handle, engine_pause(handle));
    const auto paused = Frame(handle);
    Require(paused.frame_serial == frame.frame_serial, "Pause changed the current frame");
    Check(handle, engine_resume(handle));
    Key(handle, 13);
    std::string saved;
    for (int i = 0; i < 1800; ++i) {
        Check(handle, engine_tick(handle, 40));
        auto info = Info(handle);
        if (info.at("mode") == "story" && info.at("wait") == 3) {
            if (saved.empty()) {
                for (int tick = 0; tick < 24; ++tick) Check(handle, engine_tick(handle, 40));
                Frame(handle, work/"dialogue.ppm");
                saved = Position(info);
                Key(handle, 0x74);
                Require(Info(handle).at("menu") == 0, "Quicksave failed: " + Info(handle).dump());
                Key(handle, 13);
            } else if (Position(info) != saved) break;
            else Key(handle, 13);
        }
        if (i == 1799) throw std::runtime_error("Story did not reach two distinct dialogues: " + info.dump());
    }
    const auto progressed = Info(handle);
    Check(handle, session.Close());
    Open(session, root, work, font, true);
    handle = session.handle();
    Key(handle, 0x78);
    Check(handle, engine_tick(handle, 0));
    Require(Info(handle).at("mode") == "story" && Info(handle).at("wait") == 3 && Position(Info(handle)) == saved,
        "Reopened slot did not restore the original dialogue: " + Info(handle).dump() + " expected " + saved);
    Frame(handle, work/"loaded.ppm");
    std::cout << root.filename() << " " << frame.width << "x" << frame.height << " saved " << saved
              << " progressed " << progressed << " reopened " << Position(Info(handle)) << "\n";
    Check(handle, session.Close());
    return 0;
} catch (const std::exception &e) {
    std::cerr << e.what() << "\n"; return 1;
}
