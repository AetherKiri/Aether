#include <catch2/catch_test_macros.hpp>
#include "engine_runtime_provider.h"
#include "mages_runtime.h"
#include "impacto_host.h"
#include "gameroot.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <vector>

namespace fs = std::filesystem;
namespace {
struct TempDir {
    fs::path path = fs::temp_directory_path() / ("mages-test-" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()));
    TempDir() { fs::create_directories(path); }
    ~TempDir() { std::error_code ec; fs::remove_all(path, ec); }
    void touch(const fs::path& file) {
        fs::create_directories((path / file).parent_path());
        std::ofstream(path / file) << "marker";
    }
};

// Records the host ABI contract without substituting a CPU renderer. Actual
// shader execution and presentation are covered by godot_gpu_smoke.gd.
struct GpuRecorder {
    inline static std::map<uint64_t, std::pair<uint32_t,uint32_t>> textures;
    inline static uint64_t next = 1;
    inline static uint32_t copies = 0, reads = 0, draws = 0;
    static impacto_host_gpu_callbacks_t callbacks() {
        impacto_host_gpu_callbacks_t gpu{};
        gpu.struct_size = sizeof(gpu); gpu.api_version = IMPACTO_HOST_GPU_API_VERSION;
        gpu.create_rgba = [](uint32_t w,uint32_t h,const void*,uint32_t) -> uint64_t {
            auto id = next++; textures[id] = {w,h}; return id;
        };
        gpu.release_texture = [](uint64_t t) { REQUIRE(textures.erase(t) == 1); };
        gpu.clear_rgba = [](uint64_t t,uint32_t) -> int32_t { return textures.count(t); };
        gpu.update_rgba = [](uint64_t t,const void*,uint32_t) -> int32_t { return textures.count(t); };
        gpu.copy_rgba = [](uint64_t d,uint64_t s,uint32_t w,uint32_t h) -> int32_t {
            REQUIRE(textures.count(d)); REQUIRE(textures.count(s));
            CHECK(textures[d].first == w); CHECK(textures[d].second == h);
            ++copies; return 1;
        };
        gpu.read_rgba = [](uint64_t,void*,size_t,uint32_t) -> int32_t { ++reads; return 1; };
        gpu.draw = [](const impacto_host_gpu_draw_t* d) -> int32_t {
            REQUIRE(d->struct_size == sizeof(*d)); REQUIRE(textures.count(d->target));
            REQUIRE(d->vertices); REQUIRE(d->uniforms);
            CHECK(d->vertex_float_count == d->vertex_count * 10);
            for(auto t : d->textures) REQUIRE(textures.count(t));
            ++draws; return 1;
        };
        return gpu;
    }
};
engine_handle_t create(const fs::path& writable) {
    const auto utf8 = writable.u8string();
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc); desc.api_version = ENGINE_API_VERSION;
    desc.writable_path_utf8 = utf8.c_str(); desc.cache_path_utf8 = utf8.c_str();
    engine_handle_t handle = nullptr;
    REQUIRE(engine_create(&desc, &handle) == ENGINE_RESULT_OK);
    engine_option_t option{"runtime", "mages"};
    REQUIRE(engine_set_option(handle,&option) == ENGINE_RESULT_OK);
    return handle;
}
}

TEST_CASE("MAGES. registers as one shared runtime provider") {
    aetherkiri::mages::RegisterRuntimeProvider();
    aetherkiri::mages::RegisterRuntimeProvider();
    uint32_t matches = 0;
    for(uint32_t i = 0; i < engine_get_runtime_provider_count(); ++i) {
        char id[64]{};
        uint32_t written = 0;
        REQUIRE(engine_get_runtime_provider_id(i,id,sizeof(id),&written) == ENGINE_RESULT_OK);
        if(std::string(id) == "mages") ++matches;
    }
    CHECK(matches == 1);
}

TEST_CASE("MAGES. probing and archive resolution share supported layouts") {
    aetherkiri::mages::RegisterRuntimeProvider();
    TempDir root;
    auto check = [&](const fs::path& path, const char* id) {
        auto result = Impacto::Host::DetectGameRoot(path);
        REQUIRE(result); CHECK(result->Id == id);
        CHECK(engine_probe_runtime_provider("mages",path.u8string().c_str()) > 0);
    };
    SECTION("MO8 real nested Steam directory and direct root") {
        root.touch("MemoriesoffIF/SCRIPT.MPK"); root.touch("MemoriesoffIF/system.mpk");
        root.touch("MemoriesoffIF/bg1.mpk");
        check(root.path,"mo8"); check(root.path/"MemoriesoffIF","mo8");
        Impacto::Host::ArchiveRoot = root.path/"MemoriesoffIF";
        Impacto::Host::ProfileArchiveRoot = root.path;
        CHECK(Impacto::Host::ResolveArchivePath((root.path/"script.mpk").string()) ==
              (root.path/"MemoriesoffIF/SCRIPT.MPK").string());
        Impacto::Host::ArchiveRoot.clear(); Impacto::Host::ProfileArchiveRoot.clear();
    }
    SECTION("all registered named layouts") {
        for(const auto& id : {"chlcc","darling","rne","cclcc","dash","mo6tw","mo8"}) {
            TempDir game;
            game.touch(fs::path(id)/(std::string(id) == "mo8" ? "system.mpk" :
                std::string(id) == "cclcc" ? "system.mpk" :
                std::string(id) == "dash" ? "system.cls" : "system.cpk"));
            check(game.path,id); check(game.path/id,id);
        }
    }
    SECTION("unnamed RNE and DaSH archives") {
        root.touch("script.cls"); root.touch("model.cpk"); root.touch("system.cpk");
        check(root.path,"rne");
    }
    SECTION("unknown and ambiguous archives are rejected") {
        root.touch("mo7/script.cls"); root.touch("script.mpk"); root.touch("system.mpk");
        CHECK_FALSE(Impacto::Host::DetectGameRoot(root.path));
        CHECK(engine_probe_runtime_provider("mages",root.path.u8string().c_str()) == 0);
    }
}

TEST_CASE("MAGES. requires a GPU host for opening") {
    aetherkiri::mages::RegisterRuntimeProvider();
    aetherkiri::mages::RegisterGpuBridge(nullptr);
    TempDir root, writable;
    root.touch("mo8/system.mpk");
    auto handle = create(writable.path);
    CHECK(engine_open_game(handle,root.path.u8string().c_str(),nullptr) != ENGINE_RESULT_OK);
    REQUIRE(engine_destroy(handle) == ENGINE_RESULT_OK);
}

TEST_CASE("MAGES. rejects invalid archives and unsupported roots cleanly") {
    aetherkiri::mages::RegisterRuntimeProvider();
    auto gpu = GpuRecorder::callbacks();
    aetherkiri::mages::RegisterGpuBridge(&gpu);
    TempDir root, writable;
    root.touch("mo8/system.mpk");
    auto handle = create(writable.path);
    CHECK(engine_open_game(handle,root.path.u8string().c_str(),nullptr) != ENGINE_RESULT_OK);
    REQUIRE(engine_destroy(handle) == ENGINE_RESULT_OK);
    CHECK(GpuRecorder::textures.empty());
    aetherkiri::mages::RegisterGpuBridge(nullptr);
}

TEST_CASE("MAGES. launcher publishes native textures without presentation readback") {
    for (int session = 0; session < 3; ++session) {
        TempDir root, writable;
        impacto_host_desc_t desc{};
        desc.struct_size = sizeof(desc); desc.api_version = IMPACTO_HOST_API_VERSION;
        const auto wr = writable.path.string();
        desc.data_dir_utf8 = AETHERKIRI_MAGES_TEST_DATA_DIR;
        desc.writable_dir_utf8 = wr.c_str(); desc.initial_width = 640; desc.initial_height = 360;
        void* host = nullptr;
        REQUIRE(impacto_host_create(&desc,&host) == IMPACTO_HOST_OK);
        auto gpu = GpuRecorder::callbacks();
        auto invalid = gpu;
        invalid.draw = nullptr;
        CHECK(impacto_host_set_gpu_callbacks(host,&invalid) == IMPACTO_HOST_INVALID_ARGUMENT);
        invalid = gpu; invalid.struct_size--;
        CHECK(impacto_host_set_gpu_callbacks(host,&invalid) == IMPACTO_HOST_INVALID_ARGUMENT);
        invalid = gpu; invalid.api_version++;
        CHECK(impacto_host_set_gpu_callbacks(host,&invalid) == IMPACTO_HOST_INVALID_ARGUMENT);
        REQUIRE(impacto_host_set_gpu_callbacks(host,&gpu) == IMPACTO_HOST_OK);
        GpuRecorder::copies = GpuRecorder::reads = 0;
        REQUIRE(impacto_host_open_game(host,root.path.string().c_str(),"launcher",nullptr) == IMPACTO_HOST_OK);
        uint64_t texture = 0, serial = 0;
        uint32_t w = 0, h = 0;
        REQUIRE(impacto_host_get_gpu_frame(host,&texture,&w,&h,&serial) == IMPACTO_HOST_OK);
        CHECK(texture != 0); CHECK(w == 640); CHECK(h == 360);
        const auto first = serial;
        REQUIRE(impacto_host_tick(host,16) == IMPACTO_HOST_OK);
        REQUIRE(impacto_host_get_gpu_frame(host,&texture,&w,&h,&serial) == IMPACTO_HOST_OK);
        CHECK(serial > first); CHECK(GpuRecorder::copies >= 2); CHECK(GpuRecorder::reads == 0);
        impacto_host_destroy(host);
        CHECK(GpuRecorder::textures.empty());
    }
}

TEST_CASE("MAGES. profile errors return to the host and allow another open") {
    TempDir data, root, writable;
    const auto definitions = data.path / "gamedefinitions.lua";
    const char* failedGame = "launcher";
    SECTION("invalid Lua registry") {
        std::ofstream(definitions) << "root.GameDefinitions = { broken syntax";
    }
    SECTION("profile fails before audio and video creation") {
        fs::copy_file(fs::path(AETHERKIRI_MAGES_TEST_DATA_DIR) / "gamedefinitions.lua", definitions);
        data.touch("profiles/mo8/game.lua");
        std::ofstream(data.path / "profiles/mo8/game.lua") <<
            "root.LayerCount = 1; root.GameFeatures = GameFeature.Audio | GameFeature.Video;";
        failedGame = "mo8";
    }
    impacto_host_desc_t desc{};
    desc.struct_size = sizeof(desc); desc.api_version = IMPACTO_HOST_API_VERSION;
    const auto dataPath = data.path.string(), wr = writable.path.string();
    desc.data_dir_utf8 = dataPath.c_str(); desc.writable_dir_utf8 = wr.c_str();
    desc.initial_width = 640; desc.initial_height = 360;
    void* host = nullptr;
    REQUIRE(impacto_host_create(&desc, &host) == IMPACTO_HOST_OK);
    auto gpu = GpuRecorder::callbacks();
    REQUIRE(impacto_host_set_gpu_callbacks(host, &gpu) == IMPACTO_HOST_OK);
    CHECK(impacto_host_open_game(host, root.path.string().c_str(), failedGame, nullptr) != IMPACTO_HOST_OK);
    CHECK(GpuRecorder::textures.empty());
    fs::copy_file(fs::path(AETHERKIRI_MAGES_TEST_DATA_DIR) / "gamedefinitions.lua",
                  definitions, fs::copy_options::overwrite_existing);
    REQUIRE(impacto_host_open_game(host, root.path.string().c_str(), "launcher", nullptr) == IMPACTO_HOST_OK);
    REQUIRE(impacto_host_tick(host, 16) == IMPACTO_HOST_OK);
    impacto_host_destroy(host);
    CHECK(GpuRecorder::textures.empty());
}

TEST_CASE("MAGES. GPU startup failures release textures and permit reopening") {
    TempDir root, writable;
    impacto_host_desc_t desc{};
    desc.struct_size = sizeof(desc); desc.api_version = IMPACTO_HOST_API_VERSION;
    const auto wr = writable.path.string();
    desc.data_dir_utf8 = AETHERKIRI_MAGES_TEST_DATA_DIR;
    desc.writable_dir_utf8 = wr.c_str();
    desc.initial_width = 640; desc.initial_height = 360;
    void* host = nullptr;
    REQUIRE(impacto_host_create(&desc, &host) == IMPACTO_HOST_OK);
    auto gpu = GpuRecorder::callbacks();
    SECTION("first frame publish failure") {
        gpu.copy_rgba = [](uint64_t, uint64_t, uint32_t, uint32_t) -> int32_t { return 0; };
    }
    SECTION("partial renderer allocation failure") {
        gpu.create_rgba = [](uint32_t w, uint32_t h, const void*, uint32_t) -> uint64_t {
            if (!GpuRecorder::textures.empty()) return 0;
            const auto id = GpuRecorder::next++;
            GpuRecorder::textures[id] = {w, h};
            return id;
        };
    }
    REQUIRE(impacto_host_set_gpu_callbacks(host, &gpu) == IMPACTO_HOST_OK);
    CHECK(impacto_host_open_game(host, root.path.string().c_str(), "launcher", nullptr) != IMPACTO_HOST_OK);
    CHECK(GpuRecorder::textures.empty());
    gpu = GpuRecorder::callbacks();
    REQUIRE(impacto_host_set_gpu_callbacks(host, &gpu) == IMPACTO_HOST_OK);
    REQUIRE(impacto_host_open_game(host, root.path.string().c_str(), "launcher", nullptr) == IMPACTO_HOST_OK);
    REQUIRE(impacto_host_tick(host, 16) == IMPACTO_HOST_OK);
    impacto_host_destroy(host);
    CHECK(GpuRecorder::textures.empty());
}
