#ifndef AETHERKIRI_MAGES_RUNTIME_PROVIDER_H_
#define AETHERKIRI_MAGES_RUNTIME_PROVIDER_H_
#include "impacto_host_gpu.h"
#include <string>

namespace aetherkiri::mages {

/* Registers the embedded MAGES. (impacto) runtime provider with engine_api.
 * Safe to call multiple times; registration failures only make the runtime
 * unavailable. */
void RegisterRuntimeProvider();
void RegisterGpuBridge(const impacto_host_gpu_callbacks_t* callbacks);
void SetDataDirectory(const std::string& directory);

}  // namespace aetherkiri::mages

#endif  // AETHERKIRI_MAGES_RUNTIME_PROVIDER_H_
