#include <catch2/catch_test_macros.hpp>
#include "engine_api.h"
#include "engine_runtime_provider.h"
#include <chrono>
#include <filesystem>
#include <string>

namespace {
struct State {
  uint32_t width = 0, height = 0;
  std::string calls;
} state;

const engine_runtime_provider_v1_t provider = [] {
  engine_runtime_provider_v1_t api{};
  api.struct_size = sizeof(api);
  api.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
  api.runtime_id_utf8 = "provider-only-surface-test";
  api.display_name_utf8 = "Provider-only presentation contract";
  api.probe = [](void*, const char*) -> int32_t { return 100; };
  api.create = [](void*, const engine_runtime_host_v1_t*,
                  const engine_create_desc_t*, void** output) {
    state.calls += 'C';
    *output = &state;
    return ENGINE_RESULT_OK;
  };
  api.destroy = [](void*) { state.calls += 'D'; };
  api.set_surface_size = [](void*, uint32_t width, uint32_t height) {
    state.calls += 'S';
    state.width = width;
    state.height = height;
    return ENGINE_RESULT_OK;
  };
  api.open_game = [](void*, const char*, const char*) {
    state.calls += 'O';
    return state.width == 640 && state.height == 360
               ? ENGINE_RESULT_OK : ENGINE_RESULT_INTERNAL_ERROR;
  };
  api.tick = [](void*, uint32_t) { return ENGINE_RESULT_OK; };
  return api;
}();

struct Fixture {
  engine_handle_t handle = nullptr;
  std::filesystem::path path = std::filesystem::temp_directory_path() /
      ("aether-provider-only-" + std::to_string(
          std::chrono::steady_clock::now().time_since_epoch().count()));
  ~Fixture() {
    if (handle) engine_destroy(handle);
    std::error_code error;
    std::filesystem::remove_all(path, error);
  }
};
}  // namespace

TEST_CASE("Provider-only hosts replay pre-open surface dimensions") {
  Fixture fixture;
  std::filesystem::create_directories(fixture.path);
  const std::string root = fixture.path.u8string();
  REQUIRE(engine_register_runtime_provider(&provider) == ENGINE_RESULT_OK);
  engine_create_desc_t desc{};
  desc.struct_size = sizeof(desc);
  desc.api_version = ENGINE_API_VERSION;
  desc.writable_path_utf8 = root.c_str();
  desc.cache_path_utf8 = root.c_str();
  REQUIRE(engine_create(&desc, &fixture.handle) == ENGINE_RESULT_OK);
  REQUIRE(engine_set_surface_size(fixture.handle, 320, 180) == ENGINE_RESULT_OK);
  REQUIRE(engine_set_surface_size(fixture.handle, 640, 360) == ENGINE_RESULT_OK);
  REQUIRE(state.calls.empty());
  REQUIRE(engine_set_surface_size(fixture.handle, 0, 999) == ENGINE_RESULT_INVALID_ARGUMENT);
  REQUIRE(engine_set_surface_size(fixture.handle, 999, 0) == ENGINE_RESULT_INVALID_ARGUMENT);
  engine_option_t runtime{};
  runtime.key_utf8 = "runtime";
  runtime.value_utf8 = provider.runtime_id_utf8;
  REQUIRE(engine_set_option(fixture.handle, &runtime) == ENGINE_RESULT_OK);
  REQUIRE(engine_open_game(fixture.handle, root.c_str(), nullptr) == ENGINE_RESULT_OK);
  REQUIRE(state.calls == "CSO");
  REQUIRE(state.width == 640);
  REQUIRE(state.height == 360);
  REQUIRE(engine_set_surface_size(fixture.handle, 800, 450) == ENGINE_RESULT_OK);
  REQUIRE(state.calls == "CSOS");
  REQUIRE(state.width == 800);
  REQUIRE(state.height == 450);
}
