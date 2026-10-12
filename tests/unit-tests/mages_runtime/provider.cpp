#include <catch2/catch_test_macros.hpp>

#include "engine_runtime_provider.h"
#include "mages_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {
    std::string MagesDataDir() {
        if(const char* override_dir = std::getenv("AETHERKIRI_MAGES_DATA_DIR")) {
            if(override_dir[0] != '\0') return std::string(override_dir);
        }
#ifdef AETHERKIRI_MAGES_TEST_DATA_DIR
        return std::string(AETHERKIRI_MAGES_TEST_DATA_DIR);
#else
        return std::string();
#endif
    }

    bool MagesPackageAvailable() {
        const std::string dir = MagesDataDir();
        return !dir.empty() &&
               fs::exists(fs::path(dir) / "lib" / "libimpacto_host.so") &&
               fs::exists(fs::path(dir) / "include" / "impacto_host.h");
    }

    fs::path MakeLauncherGameRoot() {
        const auto nonce =
            std::chrono::steady_clock::now().time_since_epoch().count();
        const fs::path root = fs::temp_directory_path() /
            ("aetherkiri-mages-provider-" + std::to_string(nonce));
        // Empty root: no MAGES. install layout, so the provider opens the
        // engine's data-free launcher loop, which renders full
        // design-resolution frames headlessly. A real install follows the
        // <game-id>/script.* layout instead.
        fs::create_directories(root);
        return root;
    }
}  // namespace

TEST_CASE("MAGES. registers as one shared runtime provider") {
    aetherkiri::mages::RegisterRuntimeProvider();
    aetherkiri::mages::RegisterRuntimeProvider();

    bool found = false;
    for(uint32_t index = 0; index < engine_get_runtime_provider_count();
        ++index) {
        char id[64] = {};
        uint32_t bytes_written = 0;
        REQUIRE(engine_get_runtime_provider_id(
                    index, id, sizeof(id), &bytes_written) == ENGINE_RESULT_OK);
        if(std::string(id, bytes_written) == "mages") {
            found = true;
        }
    }
    CHECK(found);
}

TEST_CASE("MAGES. provider probes install-layout markers without creating "
          "a runtime") {
    aetherkiri::mages::RegisterRuntimeProvider();
    const auto nonce =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() /
        ("aetherkiri-mages-probe-" + std::to_string(nonce));
    // Any <game-id>/ directory with a script/system archive marks a MAGES.
    // install; the concrete game is resolved against the host registry on
    // open. mo8 here is just a registered example.
    REQUIRE(fs::create_directories(root / "mo8"));
    {
        std::ofstream marker(root / "mo8" / "script.cls", std::ios::binary);
        REQUIRE(marker.good());
        marker << "marker";
    }

    CHECK(engine_probe_runtime_provider("mages", root.u8string().c_str()) >
          0);

    // The provider probes the install layout, not a specific game: an
    // unregistered game-id directory still matches.
    const fs::path unregistered_root = fs::temp_directory_path() /
        ("aetherkiri-mages-probe-unregistered-" + std::to_string(nonce));
    REQUIRE(fs::create_directories(unregistered_root / "mo7"));
    {
        std::ofstream marker(unregistered_root / "mo7" / "script.cls",
                             std::ios::binary);
        REQUIRE(marker.good());
        marker << "marker";
    }
    CHECK(engine_probe_runtime_provider(
              "mages", unregistered_root.u8string().c_str()) > 0);

    // A directory without MAGES. markers must not match.
    const fs::path empty_root = fs::temp_directory_path() /
        ("aetherkiri-mages-probe-empty-" + std::to_string(nonce));
    REQUIRE(fs::create_directories(empty_root));
    CHECK(engine_probe_runtime_provider(
              "mages", empty_root.u8string().c_str()) == 0);

    std::error_code error;
    fs::remove_all(root, error);
    fs::remove_all(unregistered_root, error);
    fs::remove_all(empty_root, error);
}

namespace {
engine_handle_t CreateMagesRuntime(const fs::path& writable) {
    // Keep the UTF-8 copies alive for the engine_create call: binding
    // desc pointers to u8string() temporaries would dangle.
    const std::string writable_utf8 = writable.u8string();
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    desc.api_version = ENGINE_API_VERSION;
    desc.writable_path_utf8 = writable_utf8.c_str();
    desc.cache_path_utf8 = writable_utf8.c_str();

    engine_handle_t handle = nullptr;
    REQUIRE(engine_create(&desc, &handle) == ENGINE_RESULT_OK);
    REQUIRE(handle != nullptr);

    engine_option_t runtime_option{};
    runtime_option.key_utf8 = "runtime";
    runtime_option.value_utf8 = "mages";
    REQUIRE(engine_set_option(handle, &runtime_option) == ENGINE_RESULT_OK);
    return handle;
}
}  // namespace

TEST_CASE("MAGES. runtime rejects marker-only game roots cleanly") {
    if(!MagesPackageAvailable()) {
        SUCCEED("AetherMAGES host package unavailable; skipping");
        return;
    }
    aetherkiri::mages::RegisterRuntimeProvider();

    const auto nonce =
        std::chrono::steady_clock::now().time_since_epoch().count();

    // A marker-only mo8 root: the layout matches, the host resolves the
    // registered mo8 id, and the engine then fails on the marker archives.
    // The open must surface an error (not the launcher loop) and leave the
    // runtime destroyable.
    const fs::path game_root = fs::temp_directory_path() /
        ("aetherkiri-mages-open-marker-" + std::to_string(nonce));
    REQUIRE(fs::create_directories(game_root / "mo8"));
    {
        std::ofstream marker(game_root / "mo8" / "script.cls",
                             std::ios::binary);
        REQUIRE(marker.good());
        marker << "marker";
    }
    const fs::path writable =
        fs::temp_directory_path() / (game_root.filename().string() + "-wr");
    fs::create_directories(writable);

    {
        engine_handle_t handle = CreateMagesRuntime(writable);
        CHECK(engine_open_game(handle, game_root.u8string().c_str(),
                               nullptr) != ENGINE_RESULT_OK);
        REQUIRE(engine_destroy(handle) == ENGINE_RESULT_OK);
    }

    // An unregistered game-id directory: detected by the layout probe, but
    // the host registry has no such game, so the open fails with an error
    // naming the missing game data.
    const fs::path unknown_root = fs::temp_directory_path() /
        ("aetherkiri-mages-open-unknown-" + std::to_string(nonce));
    REQUIRE(fs::create_directories(unknown_root / "mo7"));
    {
        std::ofstream marker(unknown_root / "mo7" / "script.cls",
                             std::ios::binary);
        REQUIRE(marker.good());
        marker << "marker";
    }
    const fs::path unknown_writable =
        fs::temp_directory_path() / (unknown_root.filename().string() + "-wr");
    fs::create_directories(unknown_writable);

    {
        engine_handle_t handle = CreateMagesRuntime(unknown_writable);
        CHECK(engine_open_game(handle, unknown_root.u8string().c_str(),
                               nullptr) != ENGINE_RESULT_OK);
        REQUIRE(engine_destroy(handle) == ENGINE_RESULT_OK);
    }

    std::error_code error;
    fs::remove_all(game_root, error);
    fs::remove_all(writable, error);
    fs::remove_all(unknown_root, error);
    fs::remove_all(unknown_writable, error);
}

TEST_CASE("MAGES. runtime opens and renders headless frames") {
    if(!MagesPackageAvailable()) {
        SUCCEED("AetherMAGES host package unavailable; skipping");
        return;
    }
    aetherkiri::mages::RegisterRuntimeProvider();

    const fs::path game_root = MakeLauncherGameRoot();
    const fs::path writable = fs::temp_directory_path() /
        (game_root.filename().string() + "-writable");
    fs::create_directories(writable);

    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    desc.api_version = ENGINE_API_VERSION;
    const std::string writable_utf8 = writable.u8string();
    desc.writable_path_utf8 = writable_utf8.c_str();
    desc.cache_path_utf8 = writable_utf8.c_str();

    engine_handle_t handle = nullptr;
    REQUIRE(engine_create(&desc, &handle) == ENGINE_RESULT_OK);
    REQUIRE(handle != nullptr);

    engine_option_t runtime_option{};
    runtime_option.key_utf8 = "runtime";
    runtime_option.value_utf8 = "mages";
    REQUIRE(engine_set_option(handle, &runtime_option) == ENGINE_RESULT_OK);

    REQUIRE(engine_open_game(handle, game_root.u8string().c_str(),
                             nullptr) == ENGINE_RESULT_OK);

    // Run two seconds of engine time: enough for the boot sequence to settle
    // into a rendered 1920x1080 frame on the offscreen renderer.
    uint32_t width = 0, height = 0, stride = 0;
    bool have_frame = false;
    for(int frame = 0; frame < 120; ++frame) {
        const engine_result_t tick = engine_tick(handle, 16);
        if(tick == ENGINE_RESULT_INVALID_STATE) {
            // Engine requested termination; accept it.
            break;
        }
        REQUIRE(tick == ENGINE_RESULT_OK);

        engine_frame_desc_t frame_desc{};
        frame_desc.struct_size = sizeof(frame_desc);
        REQUIRE(engine_get_frame_desc(handle, &frame_desc) ==
                ENGINE_RESULT_OK);
        if(frame_desc.width > 0 && frame_desc.height > 0) {
            width = frame_desc.width;
            height = frame_desc.height;
            stride = frame_desc.stride_bytes;
            have_frame = true;
        }
    }

    if(have_frame) {
        // The launcher loop renders at the initial surface size, which the
        // host pins to 1920x1080 (the MAGES. era design resolution).
        CHECK(width == 1920);
        CHECK(height == 1080);
        CHECK(stride == width * 4u);

        std::vector<uint8_t> pixels(
            static_cast<size_t>(width) * height * 4u);
        REQUIRE(engine_read_frame_rgba(handle, pixels.data(), pixels.size()) ==
                ENGINE_RESULT_OK);
    }

    REQUIRE(engine_destroy(handle) == ENGINE_RESULT_OK);

    std::error_code error;
    fs::remove_all(game_root, error);
    fs::remove_all(writable, error);
}
