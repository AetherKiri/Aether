#ifndef AETHERKIRI_MAGES_RUNTIME_PROVIDER_H_
#define AETHERKIRI_MAGES_RUNTIME_PROVIDER_H_

namespace aetherkiri::mages {

/* Registers the embedded MAGES. (impacto) runtime provider with engine_api.
 * Safe to call multiple times; registration failures only make the runtime
 * unavailable. */
void RegisterRuntimeProvider();

}  // namespace aetherkiri::mages

#endif  // AETHERKIRI_MAGES_RUNTIME_PROVIDER_H_
