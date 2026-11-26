#include <catch2/catch_test_macros.hpp>

#include "aether/native_host/launch_router.h"
#include "aether/native_host/runtime_session.h"

#include <algorithm>
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

#if defined(AETHER_TEST_SYSTEM3) || defined(AETHER_TEST_XSYSTEM35) || \
    defined(AETHER_TEST_WA2) || defined(AETHER_TEST_MINORI) || defined(AETHER_TEST_N2SYSTEM)
void StartProvider(RuntimeSession &session, const engine_create_desc_t &description,
                   const std::string &path, const char *runtime, uint32_t expected) {
    REQUIRE(session.Create(description) == ENGINE_RESULT_OK);
    RuntimeSession competing;
    REQUIRE(competing.Create(description) == ENGINE_RESULT_INVALID_STATE);
    const auto engine = session.handle();
    engine_option_t option{};
    option.key_utf8 = "runtime";
    option.value_utf8 = runtime;
    REQUIRE(engine_set_option(engine, &option) == ENGINE_RESULT_OK);
    option.key_utf8 = "default_font";
    option.value_utf8 = AETHER_TEST_RUNTIME_FONT;
    REQUIRE(engine_set_option(engine, &option) == ENGINE_RESULT_OK);
    REQUIRE(engine_open_game_async(engine, path.c_str(), nullptr) == ENGINE_RESULT_OK);
    uint32_t state = ENGINE_STARTUP_STATE_IDLE;
    REQUIRE(WaitFor([&] {
        REQUIRE(engine_get_startup_state(engine, &state) == ENGINE_RESULT_OK);
        return state == ENGINE_STARTUP_STATE_SUCCEEDED || state == ENGINE_STARTUP_STATE_FAILED;
    }));
    INFO(engine_get_last_error(engine));
    REQUIRE(state == expected);
}
#endif

#if defined(AETHER_TEST_SYSTEM3)
void ExerciseSystem3(RuntimeSession &session, const engine_create_desc_t &description,
                     const fs::path &root) {
    const auto game = root / "system3-game";
    REQUIRE(fs::create_directory(game));
    const auto path = game.u8string();
    std::ofstream(game / "ACG.DAT") << "graphics marker";
    std::ofstream(game / "system3.ini") << "[config]\ngame=system3_generic\nencoding=utf8\n";
    std::ofstream(game / "ADISK.DAT") << "invalid archive";
    StartProvider(session, description, path, "system3", ENGINE_STARTUP_STATE_FAILED);
    REQUIRE(session.Close() == ENGINE_RESULT_OK);

    std::vector<uint8_t> archive(768);
    archive[0] = 2;
    archive[2] = 3;
    archive[4] = 4;
    archive[256] = 1;
    archive[257] = 1;
    const std::string page = std::string("\x02\x00", 2) + "'中文测试'A@\x02";
    std::copy(page.begin(), page.end(), archive.begin() + 512);
    std::ofstream stream(game / "ADISK.DAT", std::ios::binary);
    stream.write(reinterpret_cast<const char *>(archive.data()), archive.size());
    stream.close();
    REQUIRE(stream.good());
    StartProvider(session, description, path, "system3", ENGINE_STARTUP_STATE_SUCCEEDED);

    const auto engine = session.handle();
    REQUIRE(engine_pause(engine) == ENGINE_RESULT_OK);
    REQUIRE(engine_resume(engine) == ENGINE_RESULT_OK);
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    REQUIRE(WaitFor([&] {
        REQUIRE(engine_tick(engine, 5) == ENGINE_RESULT_OK);
        return engine_get_frame_desc(engine, &frame) == ENGINE_RESULT_OK && frame.frame_serial > 0;
    }));
    REQUIRE(frame.width == 640);
    REQUIRE(frame.height == 400);
    REQUIRE(frame.pixel_format == ENGINE_PIXEL_FORMAT_RGBA8888);
    std::vector<uint8_t> pixels(static_cast<size_t>(frame.stride_bytes) * frame.height);
    REQUIRE(engine_read_frame_rgba(engine, pixels.data(), pixels.size()) == ENGINE_RESULT_OK);
    engine_input_event_t input{};
    input.struct_size = sizeof(input);
    input.x = 320;
    input.y = 200;
    input.type = ENGINE_INPUT_EVENT_POINTER_DOWN;
    REQUIRE(engine_send_input(engine, &input) == ENGINE_RESULT_OK);
    input.type = ENGINE_INPUT_EVENT_POINTER_UP;
    REQUIRE(engine_send_input(engine, &input) == ENGINE_RESULT_OK);
    REQUIRE(session.Close() == ENGINE_RESULT_OK);
}
#endif

#if defined(AETHER_TEST_XSYSTEM35)
void ExerciseXSystem35(RuntimeSession &session, const engine_create_desc_t &description,
                       const fs::path &root) {
    const auto game = root / "xsystem35-game";
    REQUIRE(fs::create_directory(game));
    std::vector<uint8_t> archive(1024);
    archive[0] = 1;
    archive[3] = 2;
    archive[6] = 2;
    archive[256] = 1;
    archive[257] = 2;
    archive[512] = 16;
    const uint8_t page[] = {
        'S', '3', '5', '0', 16, 0, 0, 0, 38, 0, 0, 0, 0, 0, 0, 0,
        'W', 'W', 0x02, 0x80, 0x7f, 0x01, 0xe0, 0x7f, 0x58, 0x7f,
        'Y', 0x43, 0x7f, 0x41, 0x7f, '@', 26, 0, 0, 0,
    };
    archive[516] = sizeof(page);
    std::copy(std::begin(page), std::end(page), archive.begin() + 528);
    std::ofstream stream(game / "ADISK.ALD", std::ios::binary);
    stream.write(reinterpret_cast<const char *>(archive.data()), archive.size());
    stream.close();
    REQUIRE(stream.good());

    StartProvider(session, description, game.u8string(), "xsystem35", ENGINE_STARTUP_STATE_SUCCEEDED);
    const auto engine = session.handle();
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    REQUIRE(WaitFor([&] {
        REQUIRE(engine_tick(engine, 5) == ENGINE_RESULT_OK);
        return engine_get_frame_desc(engine, &frame) == ENGINE_RESULT_OK && frame.frame_serial > 0;
    }));
    REQUIRE(frame.width == 640);
    REQUIRE(frame.height == 480);
    REQUIRE(frame.pixel_format == ENGINE_PIXEL_FORMAT_RGBA8888);
    REQUIRE(engine_pause(engine) == ENGINE_RESULT_OK);
    REQUIRE(engine_resume(engine) == ENGINE_RESULT_OK);
    engine_input_event_t input{};
    input.struct_size = sizeof(input);
    input.key_code = 13;
    input.type = ENGINE_INPUT_EVENT_KEY_DOWN;
    REQUIRE(engine_send_input(engine, &input) == ENGINE_RESULT_OK);
    input.type = ENGINE_INPUT_EVENT_KEY_UP;
    REQUIRE(engine_send_input(engine, &input) == ENGINE_RESULT_OK);
    REQUIRE(session.Close() == ENGINE_RESULT_OK);
}
#endif

#if defined(AETHER_TEST_N2SYSTEM)
void ExerciseN2System(RuntimeSession &session, const engine_create_desc_t &description) {
    StartProvider(session, description, AETHER_TEST_N2SYSTEM_GAME, "n2system", ENGINE_STARTUP_STATE_SUCCEEDED);
    const auto engine = session.handle();
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    REQUIRE(WaitFor([&] {
        REQUIRE(engine_tick(engine, 5) == ENGINE_RESULT_OK);
        return engine_get_frame_desc(engine, &frame) == ENGINE_RESULT_OK && frame.frame_serial > 0;
    }));
    REQUIRE(frame.width == 320);
    REQUIRE(frame.height == 180);
    REQUIRE(frame.pixel_format == ENGINE_PIXEL_FORMAT_RGBA8888);
    std::vector<uint8_t> pixels(static_cast<size_t>(frame.stride_bytes) * frame.height);
    REQUIRE(engine_read_frame_rgba(engine, pixels.data(), pixels.size()) == ENGINE_RESULT_OK);
    REQUIRE(engine_pause(engine) == ENGINE_RESULT_OK);
    REQUIRE(engine_resume(engine) == ENGINE_RESULT_OK);
    REQUIRE(session.Close() == ENGINE_RESULT_OK);
}
#endif

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

    const auto supported = RuntimeSession::RegisterProviders();
    const auto registered = aether::native_host::RegisteredLaunchProviders();
    REQUIRE(std::find(supported.begin(), supported.end(), "onscripter") != supported.end());
    REQUIRE(std::find(registered.begin(), registered.end(), "onscripter") != registered.end());
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
#if defined(AETHER_TEST_SYSTEM3)
        if (visit == 0) {
            REQUIRE(std::find(supported.begin(), supported.end(), "system3") != supported.end());
            ExerciseSystem3(session, description, directory.path);
        }
#endif
#if defined(AETHER_TEST_XSYSTEM35)
        if (visit == 0) {
            REQUIRE(std::find(supported.begin(), supported.end(), "xsystem35") != supported.end());
            ExerciseXSystem35(session, description, directory.path);
        }
#endif
#if defined(AETHER_TEST_WA2) || defined(AETHER_TEST_MINORI) || defined(AETHER_TEST_N2SYSTEM)
        if (visit == 0) {
#if defined(AETHER_TEST_WA2)
            REQUIRE(std::find(supported.begin(), supported.end(), "wa2") != supported.end());
            const auto empty_wa2 = directory.path / "wa2-game";
            REQUIRE(fs::create_directory(empty_wa2));
            // WA2 can open its fallback UI without retail game files.
            StartProvider(session, description, empty_wa2.u8string(), "wa2", ENGINE_STARTUP_STATE_SUCCEEDED);
            REQUIRE(engine_tick(session.handle(), 16) == ENGINE_RESULT_OK);
            REQUIRE(engine_pause(session.handle()) == ENGINE_RESULT_OK);
            REQUIRE(engine_resume(session.handle()) == ENGINE_RESULT_OK);
            REQUIRE(session.Close() == ENGINE_RESULT_OK);
#endif
#if defined(AETHER_TEST_MINORI)
            REQUIRE(std::find(supported.begin(), supported.end(), "minori") != supported.end());
            StartProvider(session, description, writable_path, "minori", ENGINE_STARTUP_STATE_FAILED);
            REQUIRE(session.Close() == ENGINE_RESULT_OK);
#endif
#if defined(AETHER_TEST_N2SYSTEM)
            REQUIRE(std::find(supported.begin(), supported.end(), "n2system") != supported.end());
            ExerciseN2System(session, description);
#endif
        }
#endif
    }
}
