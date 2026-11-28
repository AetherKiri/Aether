#pragma once

#include "engine_api.h"

#include <string_view>

namespace aether::native_host {

void RegisterProviders();
bool SupportsRuntime(std::string_view runtime);
bool UseNativeSession(std::string_view runtime, std::string_view selection, bool prerelease);

// Owns an engine ABI handle. One native host session may be active in the
// process at a time. The caller serializes operations on this session, and
// uses the borrowed handle with the existing engine API until Close().
class RuntimeSession final {
public:
    RuntimeSession() = default;
    ~RuntimeSession();

    RuntimeSession(const RuntimeSession &) = delete;
    RuntimeSession &operator=(const RuntimeSession &) = delete;

    engine_result_t Create(const engine_create_desc_t &description);
    engine_result_t Close();
    engine_handle_t handle() const { return handle_; }

private:
    engine_handle_t handle_ = nullptr;
};

} // namespace aether::native_host
