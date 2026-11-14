#include "aether_n2system.h"
#include <array>
#include <thread>
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif
namespace {
struct Host {
    std::thread::id thread = std::this_thread::get_id();
    std::array<uint8_t, 16> pixels{};
    uint64_t sequence = 1;
    bool paused = false;
};
Host* Check(void* opaque) {
    auto* host = static_cast<Host*>(opaque);
    return host && host->thread == std::this_thread::get_id() ? host : nullptr;
}
}
extern "C" {
EXPORT uint32_t aether_n2system_abi_version() { return 1; }
EXPORT int aether_n2system_create(const char*, const char*, uint32_t, uint32_t, void** output) { *output = new Host; return 0; }
EXPORT int aether_n2system_tick(void* opaque, double) {
    auto* host = Check(opaque); if(!host) return -1;
    if(!host->paused) ++host->sequence;
    return 0;
}
EXPORT int aether_n2system_event(void* opaque, uint32_t type, int32_t code, float, float) {
    auto* host = Check(opaque); if(!host) return -1;
    host->pixels[0] = uint8_t(type); host->pixels[1] = uint8_t(code);
    ++host->sequence; return 0;
}
EXPORT int aether_n2system_pause(void* opaque, int paused) {
    auto* host = Check(opaque); if(!host) return -1;
    host->paused = paused != 0; return 0;
}
EXPORT int aether_n2system_frame(void* opaque, aether_n2system_frame_info* frame) {
    auto* host = Check(opaque); if(!host) return -1;
    *frame = {host->pixels.data(), 2, 2, 8, host->sequence}; return 0;
}
EXPORT int aether_n2system_status(void* opaque) {
    auto* host = Check(opaque); return host ? int(host->paused) : -1;
}
EXPORT const char* aether_n2system_last_error(void*) { return "C ABI called from wrong thread"; }
EXPORT void aether_n2system_destroy(void* opaque) {
    auto* host = Check(opaque); if(!host) std::terminate(); delete host;
}
}
