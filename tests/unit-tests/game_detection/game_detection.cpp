#include "aether/game_detection.h"
#include "engine_runtime_provider.h"

#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>

#include <chrono>
#include <filesystem>
#include <fstream>

namespace {

namespace detection = aether::game_detection;
namespace fs = std::filesystem;

struct TestDirectory {
    const fs::path root = fs::temp_directory_path() /
        ("aether-detection-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));

    TestDirectory() { REQUIRE(fs::create_directory(root)); }
    ~TestDirectory() {
        std::error_code error;
        fs::remove_all(root, error);
    }
};

engine_runtime_provider_v1_t TestProvider(const char *id, int32_t &score) {
    engine_runtime_provider_v1_t provider{};
    provider.struct_size = sizeof(provider);
    provider.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
    provider.runtime_id_utf8 = id;
    provider.provider_user_data = &score;
    provider.probe = [](void *data, const char *) { return *static_cast<int32_t *>(data); };
    // Detection never starts a session.
    provider.create = [](void *, const engine_runtime_host_v1_t *, const engine_create_desc_t *, void **) {
        return ENGINE_RESULT_INVALID_STATE;
    };
    provider.destroy = [](void *) {};
    provider.open_game = [](void *, const char *, const char *) { return ENGINE_RESULT_INVALID_STATE; };
    provider.tick = [](void *, uint32_t) { return ENGINE_RESULT_INVALID_STATE; };
    return provider;
}

} // namespace

TEST_CASE("Native detection matches the legacy provider routing matrix") {
    std::ifstream matrix(AETHER_DETECTION_PROBE_CASES);
    REQUIRE(matrix.good());
    const auto cases = nlohmann::json::parse(matrix);
    for (const auto &test : cases) {
        CAPTURE(test["name"]);
        detection::Result result;
        result.engine = test.value("direct", "kirikiri");
        result.launch_file = "recorded.xp3";
        int calls = 0;
        detection::ApplyProviderProbes(result, "/probe-root", [&](const char *id, const char *root) {
            CHECK(std::string_view(root) == "/probe-root");
            ++calls;
            return test["scores"].value(id, -1);
        });
        CHECK(result.engine == test["engine"]);
        CHECK(result.provider_score == test["score"]);
        CHECK(result.launch_file == "recorded.xp3");
        if (test.contains("direct")) {
            CHECK(calls == 0);
        }
    }
}

TEST_CASE("Standalone detection can inspect a path and reuse registered Provider probes") {
    TestDirectory directory;
    auto result = detection::DetectGame(directory.root.u8string());
    CHECK(result.engine == "kirikiri");
    CHECK(result.provider_score == 0);
    CHECK(result.signals == std::vector<std::string>{"kirikiri-xp3-or-default"});

    static int32_t escude_score = 89;
    static int32_t wa2_score = 1;
    static const auto escude = TestProvider("escude", escude_score);
    static const auto wa2 = TestProvider("wa2", wa2_score);
    REQUIRE(engine_register_runtime_provider(&escude) == ENGINE_RESULT_OK);
    REQUIRE(engine_register_runtime_provider(&wa2) == ENGINE_RESULT_OK);

    result = detection::DetectGame(directory.root.u8string());
    CHECK(result.engine == "wa2");
    CHECK(result.provider_score == 1);
    escude_score = 90;
    result = detection::DetectGame(directory.root.u8string());
    CHECK(result.engine == "escude");
    CHECK(result.provider_score == 90);

    const auto script = directory.root / "0.txt";
    std::ofstream(script) << "*define\ngame\n*start\nend\n";
    result = detection::DetectGame(script.u8string());
    CHECK(result.engine == "onscripter");
    CHECK(result.provider_score == 0);
    CHECK(result.root == directory.root.u8string());
}
