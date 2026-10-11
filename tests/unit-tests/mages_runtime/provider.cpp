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
        // Empty root: no mo8 archives, so the provider opens the engine's
        // data-free launcher loop, which renders full design-resolution
        // frames headlessly. Real mo8 data on a user system follows the
        // mo8/script.cls path instead.
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

TEST_CASE("MAGES. provider probes mo8 markers without creating a runtime") {
    aetherkiri::mages::RegisterRuntimeProvider();
    const auto nonce =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() /
        ("aetherkiri-mages-probe-" + std::to_string(nonce));
    REQUIRE(fs::create_directories(root / "mo8"));
    {
        std::ofstream marker(root / "mo8" / "script.cls", std::ios::binary);
        REQUIRE(marker.good());
        marker << "marker";
    }

    CHECK(engine_probe_runtime_provider("mages", root.u8string().c_str()) >
          0);

    // A directory without MAGES. markers must not match.
    const fs::path empty_root = fs::temp_directory_path() /
        ("aetherkiri-mages-probe-empty-" + std::to_string(nonce));
    REQUIRE(fs::create_directories(empty_root));
    CHECK(engine_probe_runtime_provider(
              "mages", empty_root.u8string().c_str()) == 0);

    std::error_code error;
    fs::remove_all(root, error);
    fs::remove_all(empty_root, error);
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
    desc.writable_path_utf8 = writable.u8string().c_str();
    desc.cache_path_utf8 = writable.u8string().c_str();

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
        // The MO8 profile renders at its 1920x1080 design resolution.
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
