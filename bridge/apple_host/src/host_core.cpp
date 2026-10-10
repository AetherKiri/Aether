// Apple-native host core library entry point (SwiftUI + Metal host).
//
// Responsibilities of this translation unit (M0):
//   * Register the runtime providers with the engine dispatcher (mirrors the
//     Godot extension's module init; registration is process-wide and
//     idempotent, hosts call it before creating the first engine handle).
//   * Install the krkr2 legacy services table at library load time, mirroring
//     the Godot extension's library-init step. The services table routes the
//     built-in "kirikiri" backend into the krkr2 glue and provides host hooks
//     (audio session, texture recycle drain, media, diagnostics, ...).
//   * Expose a minimal C surface for the ObjC++/Swift side to query the host
//     core build identity.
//
// Rendering (GPU bridge callbacks), input translation, media and platform
// request handling live in the host implementation layer; see
// doc/apple_host_seam_inventory.md for the full responsibility matrix.

#include "engine_api.h"

#include <cstdint>

#if defined(AETHERKIRI_WITH_ONSCRIPTER)
#include "onscripter_runtime.h"
#endif
#if defined(AETHERKIRI_WITH_SIGLUS)
#include "siglus_runtime.h"
#endif
#if defined(AETHERKIRI_WITH_RFVP)
#include "rfvp_runtime_provider.h"
#endif

#if defined(AETHERKIRI_WITH_KRKR2)
extern "C" engine_result_t aether_krkr2_install_legacy_services(void);
#endif
#if defined(AETHERKIRI_WITH_MINORI)
extern "C" engine_result_t aetherkiri_minori_register_runtime_provider();
#endif
#if defined(AETHERKIRI_WITH_SOFTPAL)
extern "C" void AetherSoftPalRegisterRuntime(void);
#endif

namespace {

bool InstallLegacyServices() {
#if defined(AETHERKIRI_WITH_KRKR2)
    return aether_krkr2_install_legacy_services() == ENGINE_RESULT_OK;
#else
    return true;
#endif
}

void RegisterRuntimeProviders() {
#if defined(AETHERKIRI_WITH_ONSCRIPTER)
    aetherkiri::onscripter::RegisterRuntimeProvider();
#endif
#if defined(AETHERKIRI_WITH_SIGLUS)
    aetherkiri::siglus::RegisterRuntimeProvider();
#endif
#if defined(AETHERKIRI_WITH_MINORI)
    aetherkiri_minori_register_runtime_provider();
#endif
#if defined(AETHERKIRI_WITH_RFVP)
    aetherkiri::rfvp::RegisterRuntimeProvider();
#endif
#if defined(AETHERKIRI_WITH_SOFTPAL)
    AetherSoftPalRegisterRuntime();
#endif
}

void InitializeHostCore() {
    InstallLegacyServices();
    RegisterRuntimeProviders();
}

}  // namespace

extern "C" {

#if defined(__APPLE__)
__attribute__((constructor)) static void AetherAppleHostCoreLoad() {
    InitializeHostCore();
}
#endif

// Explicit entry point for hosts that prefer ordering the install step
// themselves (idempotent; the constructor above keeps the default path
// automatic).
uint32_t aether_apple_host_core_initialize(void) {
    InitializeHostCore();
    return 1u;
}

uint32_t aether_apple_host_core_engine_api_version(void) {
    return ENGINE_API_VERSION;
}

}  // extern "C"
