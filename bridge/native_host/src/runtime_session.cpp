#include "aether/native_host/runtime_session.h"
#include "aether/native_host/launch_router.h"

#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
#include "onscripter_runtime.h"
#endif

#if defined(AETHER_NATIVE_HOST_WITH_SYSTEM3)
#include "system3_runtime_provider.h"
#endif

#include <algorithm>
#include <atomic>
#include <utility>

namespace aether::native_host {
namespace {

std::atomic<bool> session_active{false};

} // namespace

RuntimeSession::~RuntimeSession() {
    Close();
}

std::vector<std::string> RuntimeSession::RegisterProviders() {
    std::vector<std::string> candidates;
#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    aetherkiri::onscripter::RegisterRuntimeProvider();
    candidates.emplace_back("onscripter");
#endif
#if defined(AETHER_NATIVE_HOST_WITH_SYSTEM3)
    if (aetherkiri_system3_register_runtime_provider() == ENGINE_RESULT_OK) {
        candidates.emplace_back("system3");
    }
#endif
    const auto registered = RegisteredLaunchProviders();
    candidates.erase(std::remove_if(candidates.begin(), candidates.end(), [&](const auto &runtime) {
        return std::find(registered.begin(), registered.end(), runtime) == registered.end();
    }), candidates.end());
    return candidates;
}

engine_result_t RuntimeSession::Create(const engine_create_desc_t &description) {
    if (session_active.exchange(true)) {
        return ENGINE_RESULT_INVALID_STATE;
    }

    RegisterProviders();
    const auto result = engine_create(&description, &handle_);
    if (result != ENGINE_RESULT_OK) {
        session_active.store(false);
    }
    return result;
}

engine_result_t RuntimeSession::Close() {
    if (handle_ == nullptr) {
        return ENGINE_RESULT_OK;
    }
    const auto result = engine_destroy(std::exchange(handle_, nullptr));
    session_active.store(false);
    return result;
}

} // namespace aether::native_host
