#include "aether/native_host/runtime_session.h"

#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
#include "onscripter_runtime.h"
#endif

#if defined(AETHER_NATIVE_HOST_WITH_SYSTEMNNN)
#include "systemnnn_runtime.h"
#endif

#include <atomic>
#include <utility>

namespace aether::native_host {
namespace {

std::atomic<bool> session_active{false};

} // namespace

void RegisterProviders() {
#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    aetherkiri::onscripter::RegisterRuntimeProvider();
#endif
#if defined(AETHER_NATIVE_HOST_WITH_SYSTEMNNN)
    aether::systemnnn::RegisterProvider();
#endif
}

bool SupportsRuntime(std::string_view runtime) {
#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    if (runtime == "onscripter") return true;
#endif
#if defined(AETHER_NATIVE_HOST_WITH_SYSTEMNNN)
    if (runtime == "systemnnn") return true;
#endif
    return false;
}

bool UseNativeSession(std::string_view runtime, std::string_view selection, bool prerelease) {
    return SupportsRuntime(runtime) &&
           (selection == "Native Session" || (selection == "Godot Native" && prerelease));
}

RuntimeSession::~RuntimeSession() {
    Close();
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
