#include "renpy_runtime_ios_adapter.h"

#include <cstddef>
#include <mutex>

namespace {

std::mutex g_adapter_mutex;
const renpy_ios_inprocess_adapter_v1_t* g_adapter = nullptr;

bool HasRequiredPrefix(const renpy_ios_inprocess_adapter_v1_t* adapter) {
    if (!adapter || adapter->struct_size <
            offsetof(renpy_ios_inprocess_adapter_v1_t, close_game) +
                sizeof(adapter->close_game)) {
        return false;
    }
    const uint32_t expected_major =
        (AETHERKIRI_RENPY_IOS_ADAPTER_API_VERSION >> 24u) & 0xffu;
    const uint32_t adapter_major = (adapter->api_version >> 24u) & 0xffu;
    if (adapter_major != expected_major || !adapter->create ||
        !adapter->destroy || !adapter->open_game ||
        !adapter->tick || !adapter->pause || !adapter->resume ||
        !adapter->close_game || !adapter->get_last_error) {
        return false;
    }
    return true;
}

}  // namespace

extern "C" {

engine_result_t renpy_install_ios_inprocess_adapter(
    const renpy_ios_inprocess_adapter_v1_t* adapter) {
    if (adapter != nullptr && !HasRequiredPrefix(adapter)) {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(g_adapter_mutex);
    g_adapter = adapter;
    return ENGINE_RESULT_OK;
}

const renpy_ios_inprocess_adapter_v1_t*
renpy_get_ios_inprocess_adapter(void) {
    std::lock_guard<std::mutex> lock(g_adapter_mutex);
    return g_adapter;
}

}  // extern "C"
