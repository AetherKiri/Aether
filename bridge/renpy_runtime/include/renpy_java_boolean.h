#pragma once

#include <cstdint>

namespace renpy_mobile_runtime {

// Godot's Android Java wrapper assigns JNI jboolean (uint8_t) directly to
// Variant, which yields INT. Accept its exact true value without allowing
// generic Variant truthiness to report a failed bridge load as successful.
template <typename VariantValue>
bool AndroidJavaBooleanResultIsTrue(const VariantValue &result) {
    if (result.get_type() == VariantValue::BOOL) {
        return static_cast<bool>(result);
    }
    if (result.get_type() == VariantValue::INT) {
        return static_cast<int64_t>(result) == 1;
    }
    return false;
}

} // namespace renpy_mobile_runtime
