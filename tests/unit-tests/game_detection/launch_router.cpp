#include "aether/native_host/launch_router.h"

#include <catch2/catch_test_macros.hpp>

#include <algorithm>

namespace {
using namespace aether::native_host;
namespace detection = aether::game_detection;

struct FixtureFiles : detection::Files {
    std::vector<std::string> files;
    bool FileExists(const std::string &path) const override {
        return std::find(files.begin(), files.end(), path) != files.end();
    }
    bool DirectoryExists(const std::string &path) const override {
        return path == "user://a game " || path == "user://a game /nested";
    }
    std::vector<detection::DirectoryEntry> List(const std::string &, bool) const override {
        return {};
    }
    std::unique_ptr<detection::File> Open(const std::string &) const override {
        return {};
    }
};

struct RouteFixture {
    FixtureFiles files;
    LaunchCapabilities capabilities{{}, {"onscripter"}, {"tyranoscript", "renpy", "flash"}, true};
    std::string detected = "kirikiri";
    LaunchEnvironment environment{
        files, capabilities,
        [&](const std::string &root) {
            detection::Result result;
            result.root = root;
            result.engine = detected;
            return result;
        },
        [](const std::string &, const std::string &runtime) {
            return runtime == "renpy" ? "game" : "resources/app.asar";
        },
        {},
    };
    LaunchRequest request{LaunchSource::Library, "user://a game "};
    LaunchRoute Resolve() const { return ResolveLaunch(environment, request); }
};
} // namespace

TEST_CASE("Shared launch routing preserves all runtime families and engine auto dispatch") {
    RouteFixture fixture;
    for (const std::string id : {
        "kirikiri", "artemis", "onscripter", "renpy", "tyranoscript", "flash",
        "advhd", "exhibit", "bgi", "escude", "entisgls", "catsystem2", "mages", "n2system",
        "minori", "cmvs", "yuris", "siglus", "softpal", "wa2", "xsystem4", "xsystem35",
        "system3", "systemc", "rfvp",
    }) {
        CAPTURE(id);
        fixture.detected = id;
        fixture.request.source = id == "flash" ? LaunchSource::Flash : LaunchSource::Library;
        fixture.request.path = id == "flash" ? "user://movie.SWF" : "user://a game ";
        fixture.capabilities.providers = {id};

        const auto route = fixture.Resolve();
        CHECK(route.detected_runtime == id);
        CHECK(route.runtime == id);
        if (id == "tyranoscript" || id == "renpy" || id == "flash") {
            CHECK(route.player == id);
            CHECK(route.host == LaunchHost::Dedicated);
            CHECK(route.provider == ProviderStatus::NotApplicable);
        } else if (id == "kirikiri" || id == "artemis") {
            CHECK(route.engine_option == "auto");
            CHECK(route.provider == ProviderStatus::Deferred);
        } else {
            CHECK(route.engine_option == id);
            CHECK(route.host == LaunchHost::Legacy);
            CHECK(route.provider == ProviderStatus::Registered);
            fixture.capabilities.providers.clear();
            CHECK(fixture.Resolve().reason == LaunchReason::ProviderMissing);
        }
    }
}

TEST_CASE("Shared launch routing selects an ONS session and explains fallback") {
    RouteFixture fixture;
    fixture.detected = "onscripter";
    fixture.capabilities.providers = {"onscripter"};
    CHECK(fixture.Resolve().host == LaunchHost::Legacy);
    CHECK(fixture.Resolve().reason == LaunchReason::StableChannel);

    fixture.request.prerelease = true;
    CHECK(fixture.Resolve().host == LaunchHost::Native);
    fixture.request.host = HostPreference::Legacy;
    CHECK(fixture.Resolve().reason == LaunchReason::LegacyRequested);

    fixture.request.prerelease = false;
    fixture.request.host = HostPreference::Native;
    CHECK(fixture.Resolve().host == LaunchHost::Native);
    fixture.capabilities.native_sessions.clear();
    CHECK(fixture.Resolve().host == LaunchHost::Legacy);
    CHECK(fixture.Resolve().native_requested);
    CHECK(fixture.Resolve().reason == LaunchReason::NativeUnavailable);
    fixture.capabilities.providers.clear();
    CHECK(fixture.Resolve().host == LaunchHost::None);
    CHECK(fixture.Resolve().reason == LaunchReason::ProviderMissing);

    fixture.detected = "renpy";
    fixture.capabilities.dedicated_players.clear();
    CHECK(fixture.Resolve().reason == LaunchReason::PlayerUnavailable);
    fixture.environment.special_entry = [](const auto &, const auto &) { return std::string{}; };
    CHECK(fixture.Resolve().reason == LaunchReason::InvalidProject);
}

TEST_CASE("Shared launch routing preserves hand-picked files and nested runtime selection") {
    RouteFixture fixture;
    fixture.files.files = {"user://a game /nested/ My Game.XP3"};
    fixture.request.selected_file = "nested\\.\\ My Game.XP3";
    const auto route = fixture.Resolve();
    CHECK(route.entry == "user://a game /nested/ My Game.XP3");
    CHECK(route.root == "user://a game /nested");

    fixture.environment.inspect = [](const std::string &root) {
        detection::Result result;
        result.engine = root == "user://a game /nested" ? "system3" : "kirikiri";
        return result;
    };
    fixture.capabilities.providers = {"system3"};
    CHECK(fixture.Resolve().detected_runtime == "kirikiri");
    CHECK(fixture.Resolve().runtime == "system3");
    CHECK(fixture.Resolve().entry == "user://a game /nested");

    fixture.request.selected_file = "nested/absent.XP3";
    CHECK(fixture.Resolve().reason == LaunchReason::EntryMissing);
    CHECK(fixture.Resolve().error_entry == "nested/absent.XP3");
    for (const auto *entry : {"../game.xp3", "nested/../../game.xp3", "/tmp/game.xp3",
                             "C:\\game.exe", "res://movie.hcb"}) {
        CAPTURE(entry);
        fixture.request.selected_file = entry;
        CHECK(fixture.Resolve().reason == LaunchReason::EntryOutsideGame);
    }
    fixture.request.selected_file = "nested/invalid.swf";
    CHECK(fixture.Resolve().reason == LaunchReason::UnsupportedEntry);
}

TEST_CASE("Shared launch routing preserves provider startup script rules") {
    RouteFixture fixture;
    fixture.detected = "entisgls";
    fixture.capabilities.providers = {"entisgls", "yuris"};
    fixture.request.selected_file = "scripts/start.exe";
    CHECK(fixture.Resolve().entry == fixture.request.path);
    CHECK(fixture.Resolve().startup_script == "user://a game /scripts/start.exe");
    fixture.request.startup_script = "/override/start";
    CHECK(fixture.Resolve().startup_script == "/override/start");

    fixture.detected = "yuris";
    fixture.request.startup_script.clear();
    fixture.files.files = {"user://a game /data/script/UserScript/start.txt",
                           "user://a game /data/script/userscript/SCENARIO_START.yst"};
    CHECK(fixture.Resolve().startup_script == fixture.files.files[1]);
    fixture.request.source = LaunchSource::Probe;
    CHECK(fixture.Resolve().startup_script.empty());
}
