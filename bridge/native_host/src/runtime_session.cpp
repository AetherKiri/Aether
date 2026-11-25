#include "aether/native_host/runtime_session.h"

#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
#include "onscripter_runtime.h"
#endif

#include <atomic>
#include <utility>

namespace aether::native_host {
namespace {

std::atomic<bool> session_active{false};

} // namespace

RuntimeSession::~RuntimeSession() {
    Close();
}

engine_result_t RuntimeSession::Create(const engine_create_desc_t &description) {
    if (session_active.exchange(true)) {
        return ENGINE_RESULT_INVALID_STATE;
    }

#if defined(AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    aetherkiri::onscripter::RegisterRuntimeProvider();
#endif
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
