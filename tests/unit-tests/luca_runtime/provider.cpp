#include <catch2/catch_test_macros.hpp>

#include "engine_runtime_provider.h"
#include "luca_runtime.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// The luca bridge deliberately does not link engine_api (rfvp precedent):
// the test intercepts the registration call to drive the provider directly.
static const engine_runtime_provider_v1_t *provider = nullptr;
extern "C" engine_result_t engine_register_runtime_provider(
    const engine_runtime_provider_v1_t *p) {
    provider = p;
    return ENGINE_RESULT_OK;
}

namespace {

const fs::path &FixtureRoot() {
    static const fs::path root = fs::path(LUCA_SMOKE_FIXTURE_DIR);
    return root;
}

struct Instance {
    void *value = nullptr;

    Instance() {
        engine_runtime_host_v1_t host{};
        host.struct_size = sizeof(host);
        host.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        host.log = [](void *, uint32_t level, const char *, const char *text) {
            if (level >= ENGINE_RUNTIME_LOG_WARNING || std::getenv("LUCA_TRACE")) {
                std::fprintf(stderr, "[luca-test] %s\n", text);
            }
        };
        engine_create_desc_t desc{};
        desc.struct_size = sizeof(desc);
        desc.api_version = ENGINE_API_VERSION;
        REQUIRE(provider->create(nullptr, &host, &desc, &value) ==
                ENGINE_RESULT_OK);
    }

    ~Instance() {
        if (value != nullptr) {
            provider->destroy(value);
        }
    }

    engine_result_t open(const fs::path &path) {
        const auto utf8 = path.u8string();
        return provider->open_game(value, utf8.c_str(), nullptr);
    }

    engine_frame_desc_t frame() {
        engine_frame_desc_t desc{};
        desc.struct_size = sizeof(desc);
        REQUIRE(provider->get_frame_desc(value, &desc) == ENGINE_RESULT_OK);
        return desc;
    }

    std::vector<uint8_t> pixels(const engine_frame_desc_t &desc) {
        std::vector<uint8_t> bytes(
            static_cast<size_t>(desc.stride_bytes) * desc.height);
        REQUIRE(provider->read_frame_rgba(value, bytes.data(), bytes.size()) ==
                ENGINE_RESULT_OK);
        return bytes;
    }
};

std::string UniquePath(const char *tag) {
    const auto nonce =
        std::chrono::steady_clock::now().time_since_epoch().count();
    return std::string("aetherkiri-luca-") + tag + "-" + std::to_string(nonce);
}

bool PixelIs(const std::vector<uint8_t> &rgba, const engine_frame_desc_t &desc,
             uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b,
             uint8_t a) {
    const size_t index = 4 * (static_cast<size_t>(y) * desc.width + x);
    return rgba[index] == r && rgba[index + 1] == g &&
           rgba[index + 2] == b && rgba[index + 3] == a;
}

}  // namespace

TEST_CASE("Luca registers as a runtime provider") {
    aetherkiri::luca::RegisterRuntimeProvider();
    aetherkiri::luca::RegisterRuntimeProvider();
    REQUIRE(provider != nullptr);
    CHECK(std::string(provider->runtime_id_utf8) == "luca");
    CHECK(std::string(provider->display_name_utf8).find("Luca") !=
          std::string::npos);
    CHECK(provider->api_version == ENGINE_RUNTIME_PROVIDER_API_VERSION);
    CHECK(provider->struct_size >= ENGINE_RUNTIME_PROVIDER_V1_MIN_SIZE);
    CHECK(provider->priority >= 0);
    CHECK(provider->probe != nullptr);
    CHECK(provider->create != nullptr);
    CHECK(provider->destroy != nullptr);
    CHECK(provider->open_game != nullptr);
    CHECK(provider->tick != nullptr);
    CHECK(provider->get_frame_desc != nullptr);
    CHECK(provider->read_frame_rgba != nullptr);
    CHECK(provider->get_last_error != nullptr);
}

TEST_CASE("Luca probe matches only PAK game roots") {
    aetherkiri::luca::RegisterRuntimeProvider();
    REQUIRE(fs::is_directory(FixtureRoot()));
    const auto fixture = FixtureRoot().u8string();
    CHECK(provider->probe(nullptr, fixture.c_str()) > 0);

    CHECK(provider->probe(nullptr, nullptr) == 0);
    CHECK(provider->probe(nullptr, "") == 0);

    const fs::path root =
        fs::temp_directory_path() / UniquePath("probe");
    REQUIRE(fs::create_directories(root));
    CHECK(provider->probe(nullptr, root.u8string().c_str()) == 0);

    // A file named SCRIPT.PAK without a valid PAK header must not match.
    const fs::path files = root / "files";
    REQUIRE(fs::create_directories(files / "image"));
    {
        std::ofstream script(files / "SCRIPT.PAK", std::ios::binary);
        script << "not a pak header at all";
    }
    CHECK(provider->probe(nullptr, root.u8string().c_str()) == 0);

    // A valid script archive without an image family must not match.
    fs::copy(FixtureRoot() / "files" / "SCRIPT.PAK", files / "SCRIPT.PAK",
             fs::copy_options::overwrite_existing);
    CHECK(provider->probe(nullptr, root.u8string().c_str()) == 0);

    // Both markers present: full score.
    fs::copy(FixtureRoot() / "files" / "image" / "SMOKE.PAK",
             files / "image" / "SMOKE.PAK",
             fs::copy_options::overwrite_existing);
    CHECK(provider->probe(nullptr, root.u8string().c_str()) == 90);

    std::error_code ec;
    fs::remove_all(root, ec);
}

TEST_CASE("Luca vertical slice runs the script and composes the frame") {
    aetherkiri::luca::RegisterRuntimeProvider();
    Instance game;

    // Before the first tick there is no frame to read.
    REQUIRE(game.open(FixtureRoot()) == ENGINE_RESULT_OK);
    CHECK(game.frame().width == 0);
    CHECK(game.frame().height == 0);
    std::vector<uint8_t> tiny(4);
    CHECK(provider->read_frame_rgba(game.value, tiny.data(), tiny.size()) ==
          ENGINE_RESULT_INVALID_STATE);

    REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);
    const auto desc = game.frame();
    // Virtual screen (engine 1920x1080) with the fixture script's 64x48 CZ3
    // blitted at (100, 50).
    CHECK(desc.width == 1920);
    CHECK(desc.height == 1080);
    CHECK(desc.stride_bytes == 1920 * 4);
    CHECK(desc.pixel_format == ENGINE_PIXEL_FORMAT_RGBA8888);
    CHECK(desc.frame_serial == 1);

    const auto pixels = game.pixels(desc);
    CHECK(PixelIs(pixels, desc, 108, 58, 255, 0, 0, 255));
    CHECK(PixelIs(pixels, desc, 156, 58, 0, 0, 255, 255));
    CHECK(PixelIs(pixels, desc, 10, 10, 0, 0, 0, 0));
    CHECK(PixelIs(pixels, desc, 164, 58, 0, 0, 0, 0));

    // Short output buffers are rejected without touching the cache.
    std::vector<uint8_t> short_buffer(pixels);
    CHECK(provider->read_frame_rgba(game.value, short_buffer.data(),
                                    short_buffer.size() - 1) ==
          ENGINE_RESULT_INVALID_ARGUMENT);

    // Pause freezes the frame clock, resume advances it.
    const uint64_t frozen_serial = desc.frame_serial;
    REQUIRE(provider->pause(game.value) == ENGINE_RESULT_OK);
    REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);
    CHECK(game.frame().frame_serial == frozen_serial);
    REQUIRE(provider->resume(game.value) == ENGINE_RESULT_OK);
    REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);
    CHECK(game.frame().frame_serial > frozen_serial);

    // Input events are validated and accepted (routing lands with the VM).
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = ENGINE_INPUT_EVENT_POINTER_DOWN;
    event.x = 10;
    event.y = 10;
    event.button = 0;
    REQUIRE(provider->send_input(game.value, &event) == ENGINE_RESULT_OK);
    event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
    event.unicode_codepoint = 0x3042;
    REQUIRE(provider->send_input(game.value, &event) == ENGINE_RESULT_OK);

    // The CPU RGBA slice has no native texture path yet.
    uint64_t texture = 0;
    uint64_t texture_serial = 0;
    uint32_t texture_width = 0;
    uint32_t texture_height = 0;
    CHECK(provider->get_godot_native_frame_texture(
              game.value, &texture, &texture_width, &texture_height,
              &texture_serial) == ENGINE_RESULT_NOT_SUPPORTED);

    char renderer[128] = {};
    REQUIRE(provider->get_renderer_info(game.value, renderer,
                                        sizeof(renderer)) == ENGINE_RESULT_OK);
    CHECK(std::string(renderer).find("runtime=luca") != std::string::npos);

    // Rendered flag flips until the frame is delivered again.
    uint32_t rendered = 0;
    REQUIRE(provider->get_frame_rendered_flag(game.value, &rendered) ==
            ENGINE_RESULT_OK);
    CHECK(rendered == 1);
    const auto delivered = game.pixels(game.frame());
    CHECK(delivered.size() == pixels.size());
    REQUIRE(provider->get_frame_rendered_flag(game.value, &rendered) ==
            ENGINE_RESULT_OK);
    CHECK(rendered == 0);

    // A second instance is fully isolated from the first.
    Instance second;
    REQUIRE(second.open(FixtureRoot()) == ENGINE_RESULT_OK);
    REQUIRE(provider->tick(second.value, 16) == ENGINE_RESULT_OK);
    const auto second_desc = second.frame();
    CHECK(second_desc.width == desc.width);
    CHECK(second_desc.height == desc.height);
}

TEST_CASE("Luca open rejects invalid roots") {
    aetherkiri::luca::RegisterRuntimeProvider();
    Instance game;
    CHECK(game.open("") == ENGINE_RESULT_INVALID_ARGUMENT);

    const fs::path missing =
        fs::temp_directory_path() / UniquePath("missing");
    CHECK(game.open(missing) == ENGINE_RESULT_IO_ERROR);
    const char *error = provider->get_last_error(game.value);
    REQUIRE(error != nullptr);
    CHECK(std::string(error).find("luca_ak_open") != std::string::npos);
}

TEST_CASE("Luca movie latch reports idle and finishes idempotently") {
    aetherkiri::luca::RegisterRuntimeProvider();
    Instance game;
    REQUIRE(game.open(FixtureRoot()) == ENGINE_RESULT_OK);
    REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);

    // No MOVIE executed: renderer-info reports the idle movie state
    // and the finish option is a no-op success (WA2 contract).
    char renderer[2048] = {};
    REQUIRE(provider->get_renderer_info(game.value, renderer,
                                        sizeof(renderer)) == ENGINE_RESULT_OK);
    const std::string info(renderer);
    CHECK(info.find("runtime=luca") != std::string::npos);
    CHECK(info.find("movie_state=idle") != std::string::npos);
    CHECK(info.find("movie_path=-") != std::string::npos);

    engine_option_t option{};
    option.key_utf8 = "luca.movie.finish";
    option.value_utf8 = "";
    REQUIRE(provider->set_option(game.value, &option) == ENGINE_RESULT_OK);
    // "seen" value variant also accepted.
    option.value_utf8 = "seen";
    REQUIRE(provider->set_option(game.value, &option) == ENGINE_RESULT_OK);
    // Unknown keys stay unsupported.
    option.key_utf8 = "luca.nope";
    REQUIRE(provider->set_option(game.value, &option) ==
            ENGINE_RESULT_NOT_SUPPORTED);

    char debug[2048] = {};
    REQUIRE(provider->get_plugin_debug_info(game.value, debug,
                                            sizeof(debug), nullptr) ==
            ENGINE_RESULT_OK);
    CHECK(std::string(debug).find("movieWaiting=0") != std::string::npos);
}

TEST_CASE("Luca title screen boots the engine boot order") {
    // Title mode needs the SYSCG art family; the smoke fixture has none
    // (it boots straight into the script — covered by the vertical-slice
    // test). When a real game root is available, the provider opens with
    // the title screen: pointer events route through the select channel
    // and START launches the flow script.
    const char *root_env = std::getenv("AETHERLUCA_GAME_ROOT");
    fs::path root = root_env != nullptr
        ? fs::path(root_env)
        : fs::path("/Volumes/yorkyang2333/LUCA/Summer Pockets REFLECTION BLUE");
    if(!fs::is_regular_file(root / "files" / "image" / "SYSCG.PAK")) {
        SKIP("no real game root with SYSCG assets");
    }

    aetherkiri::luca::RegisterRuntimeProvider();
    Instance game;
    REQUIRE(game.open(root) == ENGINE_RESULT_OK);
    REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);

    // Debug info mirrors the title phase (engine cTitleMenu before any
    // script — notes/018).
    {
        char debug[2048] = {};
        REQUIRE(provider->get_plugin_debug_info(game.value, debug,
                                                sizeof(debug), nullptr) ==
                ENGINE_RESULT_OK);
        CHECK(std::string(debug).find("titleWaiting=1") != std::string::npos);
    }

    // The title renders the white engine fill (65001) with art on top:
    // sample a corner far from the right-side art and menu.
    const auto desc = game.frame();
    REQUIRE(desc.width == 1920);
    REQUIRE(desc.height == 1080);
    const auto pixels = game.pixels(desc);
    const size_t corner = 4 * (40 * 1920 + 40);
    CHECK(pixels[corner + 3] == 255);
    CHECK(pixels[corner] > 200);
    CHECK(pixels[corner + 1] > 200);
    CHECK(pixels[corner + 2] > 200);

    // Pointer events are consumed through the select channel (title).
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = ENGINE_INPUT_EVENT_POINTER_MOVE;
    event.x = 300;
    event.y = 600;
    REQUIRE(provider->send_input(game.value, &event) == ENGINE_RESULT_OK);
    // Fade-in completes, then START (x≈300, y≈600) launches the game.
    for(int i = 0; i < 48; ++i) {
        REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);
    }
    event.type = ENGINE_INPUT_EVENT_POINTER_DOWN;
    event.button = 0;
    REQUIRE(provider->send_input(game.value, &event) == ENGINE_RESULT_OK);
    // The title layer closes: debug info mirrors the transition
    // (titleWaiting flips to 0 once the flow script owns the frame).
    char debug[2048] = {};
    bool closed = false;
    for(int i = 0; i < 96 && !closed; ++i) {
        REQUIRE(provider->tick(game.value, 16) == ENGINE_RESULT_OK);
        REQUIRE(provider->get_plugin_debug_info(game.value, debug,
                                                sizeof(debug), nullptr) ==
                ENGINE_RESULT_OK);
        closed = std::string(debug).find("titleWaiting=0") != std::string::npos;
    }
    CHECK(closed);
}

TEST_CASE("Luca save-slot load option validates and applies") {
    aetherkiri::luca::RegisterRuntimeProvider();
    Instance game;
    REQUIRE(game.open(FixtureRoot()) == ENGINE_RESULT_OK);

    engine_option_t option{};
    option.key_utf8 = "luca.load.slot";

    // Range / format validation (engine slot space: 1..=300).
    option.value_utf8 = "0";
    CHECK(provider->set_option(game.value, &option) ==
          ENGINE_RESULT_INVALID_ARGUMENT);
    option.value_utf8 = "301";
    CHECK(provider->set_option(game.value, &option) ==
          ENGINE_RESULT_INVALID_ARGUMENT);
    option.value_utf8 = "not-a-number";
    CHECK(provider->set_option(game.value, &option) ==
          ENGINE_RESULT_INVALID_ARGUMENT);

    // The smoke fixture has no savedata: a valid slot number reports an
    // IO error with the empty-slot detail, not a crash.
    option.value_utf8 = "1";
    const engine_result_t empty = provider->set_option(game.value, &option);
    CHECK(empty == ENGINE_RESULT_IO_ERROR);
    const char *error = provider->get_last_error(game.value);
    REQUIRE(error != nullptr);
    CHECK(std::string(error).find("luca_ak_load_slot") != std::string::npos);
}
