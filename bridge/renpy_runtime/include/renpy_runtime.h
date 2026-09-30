#pragma once

namespace aetherkiri::renpy {

// Registers the opt-in Ren'Py SDK subprocess provider.  The provider only
// builds when AETHERKIRI_RENPY_SDK_ROOT names an official SDK checkout.  The
// SDK owns its window; frame import into AetherKiri is intentionally reported
// as unsupported until a real shared-surface bridge is available.
void RegisterRuntimeProvider();

}  // namespace aetherkiri::renpy
