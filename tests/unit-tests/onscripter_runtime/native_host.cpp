#include <catch2/catch_test_macros.hpp>

#include "aether/native_host/runtime_session.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace {

namespace fs = std::filesystem;
using namespace std::chrono_literals;
using aether::native_host::RuntimeSession;

struct TestDirectory {
    const fs::path path = fs::temp_directory_path() /
        ("aether-native-ons-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));

    TestDirectory() { REQUIRE(fs::create_directory(path)); }

    ~TestDirectory() {
        std::error_code error;
        fs::remove_all(path, error);
    }
};

template <typename Predicate>
bool WaitFor(Predicate ready) {
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    do {
        if (ready()) {
            return true;
        }
        std::this_thread::sleep_for(5ms);
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}

bool FrameHasShade(engine_handle_t engine, uint8_t shade, uint64_t &serial) {
    REQUIRE(engine_tick(engine, 5) == ENGINE_RESULT_OK);
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    if (engine_get_frame_desc(engine, &frame) != ENGINE_RESULT_OK) {
        return false;
    }
    REQUIRE(frame.width == 640);
    REQUIRE(frame.height == 480);
    REQUIRE(frame.pixel_format == ENGINE_PIXEL_FORMAT_RGBA8888);
    REQUIRE(frame.stride_bytes >= frame.width * 4);
    std::vector<uint8_t> pixels(static_cast<size_t>(frame.stride_bytes) * frame.height);
    REQUIRE(engine_read_frame_rgba(engine, pixels.data(), pixels.size()) == ENGINE_RESULT_OK);
    const auto center = (frame.height / 2) * frame.stride_bytes + (frame.width / 2) * 4;
    serial = frame.frame_serial;
    return pixels[center] == shade && pixels[center + 1] == shade && pixels[center + 2] == shade;
}

} // namespace

TEST_CASE("Native host plays and reopens an ONScripter game through the engine ABI") {
    TestDirectory directory;
    const fs::path game = directory.path / "game";
    REQUIRE(fs::create_directory(game));
    const std::string game_path = game.u8string();
    const std::string writable_path = directory.path.u8string();

    std::ofstream script(game / "0.txt");
    script << "*define\ncaption \"Aether native host test\"\ndeletemenu\ngame\n"
              "*start\nbg \"white\",1\nclick\nbg \"black\",1\nclick\nend\n";
    script.close();
    REQUIRE(script.good());

    engine_create_desc_t description{};
    description.struct_size = sizeof(description);
    description.api_version = ENGINE_API_VERSION;
    description.writable_path_utf8 = writable_path.c_str();
    description.cache_path_utf8 = writable_path.c_str();

    RuntimeSession session;
    auto invalid_description = description;
    invalid_description.struct_size = 0;
    REQUIRE(session.Create(invalid_description) == ENGINE_RESULT_INVALID_ARGUMENT);
    REQUIRE(session.handle() == nullptr);

    for (int visit = 0; visit < 2; ++visit) {
        CAPTURE(visit);
        REQUIRE(session.Create(description) == ENGINE_RESULT_OK);
        RuntimeSession second_session;
        REQUIRE(second_session.Create(description) == ENGINE_RESULT_INVALID_STATE);

        const auto engine = session.handle();
        engine_option_t option{};
        option.key_utf8 = "runtime";
        option.value_utf8 = "onscripter";
        REQUIRE(engine_set_option(engine, &option) == ENGINE_RESULT_OK);
        option.key_utf8 = "default_font";
        option.value_utf8 = AETHER_TEST_RUNTIME_FONT;
        REQUIRE(engine_set_option(engine, &option) == ENGINE_RESULT_OK);
        REQUIRE(engine_open_game_async(engine, game_path.c_str(), nullptr) == ENGINE_RESULT_OK);
        uint32_t startup_state = ENGINE_STARTUP_STATE_IDLE;
        REQUIRE(WaitFor([&] {
            REQUIRE(engine_get_startup_state(engine, &startup_state) == ENGINE_RESULT_OK);
            return startup_state == ENGINE_STARTUP_STATE_SUCCEEDED ||
                   startup_state == ENGINE_STARTUP_STATE_FAILED;
        }));
        INFO(engine_get_last_error(engine));
        REQUIRE(startup_state == ENGINE_STARTUP_STATE_SUCCEEDED);

        uint64_t white_frame = 0;
        REQUIRE(WaitFor([&] { return FrameHasShade(engine, 255, white_frame); }));
        REQUIRE(engine_pause(engine) == ENGINE_RESULT_OK);
        REQUIRE(engine_resume(engine) == ENGINE_RESULT_OK);

        engine_input_event_t key{};
        key.struct_size = sizeof(key);
        key.key_code = 0x0d; // Windows virtual key code for Return in the engine ABI.
        key.type = ENGINE_INPUT_EVENT_KEY_DOWN;
        REQUIRE(engine_send_input(engine, &key) == ENGINE_RESULT_OK);
        key.type = ENGINE_INPUT_EVENT_KEY_UP;
        REQUIRE(engine_send_input(engine, &key) == ENGINE_RESULT_OK);

        uint64_t black_frame = 0;
        REQUIRE(WaitFor([&] { return FrameHasShade(engine, 0, black_frame); }));
        REQUIRE(black_frame > white_frame);
        REQUIRE(session.Close() == ENGINE_RESULT_OK);
        REQUIRE(session.handle() == nullptr);
    }
}
