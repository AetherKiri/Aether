// Loaded by a real Godot executable through its generated GDExtension ABI.
// The engine creates/reads/destroys all Variants; only the production gate is
// templated. This does not execute Android's JavaClassWrapper or JNI.
#include "gdextension_interface.h"
#include "renpy_java_boolean.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

namespace {
GDExtensionInterfaceVariantGetType variant_type;
GDExtensionInterfaceVariantNewNil new_nil;
GDExtensionInterfaceVariantDestroy destroy_variant;
GDExtensionInterfaceGetVariantFromTypeConstructor from_type;
GDExtensionInterfaceGetVariantToTypeConstructor to_type;
GDExtensionInterfaceStringNewWithUtf8Chars new_string;
GDExtensionInterfaceVariantGetPtrDestructor type_destructor;
GDExtensionInterfaceGetGodotVersion godot_version;

class RealVariant {
    alignas(std::max_align_t) unsigned char storage_[AETHER_TEST_VARIANT_SIZE];

public:
    static constexpr auto BOOL = GDEXTENSION_VARIANT_TYPE_BOOL;
    static constexpr auto INT = GDEXTENSION_VARIANT_TYPE_INT;

    RealVariant(GDExtensionVariantType type, void *value) {
        if (type == GDEXTENSION_VARIANT_TYPE_NIL) {
            new_nil(storage_);
        } else {
            from_type(type)(storage_, value);
        }
    }
    RealVariant(const RealVariant &) = delete;
    RealVariant &operator=(const RealVariant &) = delete;
    ~RealVariant() { destroy_variant(storage_); }

    GDExtensionVariantType get_type() const { return variant_type(storage_); }
    explicit operator bool() const {
        if (get_type() != BOOL) std::abort();
        GDExtensionBool value;
        to_type(BOOL)(&value, const_cast<unsigned char *>(storage_));
        return value != 0;
    }
    explicit operator int64_t() const {
        if (get_type() != INT) std::abort();
        int64_t value;
        to_type(INT)(&value, const_cast<unsigned char *>(storage_));
        return value;
    }
};

int checks = 0;
void check(GDExtensionVariantType type, void *value, bool expected) {
    RealVariant actual(type, value);
    if (actual.get_type() != type ||
        renpy_mobile_runtime::AndroidJavaBooleanResultIsTrue(actual) != expected) {
        std::fprintf(stderr, "Java boolean gate failed for real Godot Variant type %d\n", type);
        std::abort();
    }
    ++checks;
}

void initialize(void *, GDExtensionInitializationLevel level) {
    if (level != GDEXTENSION_INITIALIZATION_SCENE) return;
    GDExtensionBool true_value = 1, false_value = 0;
    check(GDEXTENSION_VARIANT_TYPE_BOOL, &true_value, true);
    check(GDEXTENSION_VARIANT_TYPE_BOOL, &false_value, false);
    for (int64_t value : {int64_t(1), int64_t(0), int64_t(-1), int64_t(2), INT64_MAX}) {
        check(GDEXTENSION_VARIANT_TYPE_INT, &value, value == 1);
    }
    for (double value : {0.0, 1.0}) {
        check(GDEXTENSION_VARIANT_TYPE_FLOAT, &value, false);
    }
    check(GDEXTENSION_VARIANT_TYPE_NIL, nullptr, false);
    for (const char *text : {"true", "1"}) {
        alignas(std::max_align_t) unsigned char string_storage[AETHER_TEST_STRING_SIZE];
        new_string(string_storage, text);
        check(GDEXTENSION_VARIANT_TYPE_STRING, string_storage, false);
        type_destructor(GDEXTENSION_VARIANT_TYPE_STRING)(string_storage);
    }

    GDExtensionGodotVersion version;
    godot_version(&version);
    const char *result_path = std::getenv("AETHER_VARIANT_RESULT");
    FILE *result = result_path ? std::fopen(result_path, "w") : nullptr;
    if (!result) std::abort();
    std::fprintf(result,
        "{\"passed\":true,\"checks\":%d,\"godot\":\"%u.%u.%u\","
        "\"android_java_executed\":false}\n",
        checks, version.major, version.minor, version.patch);
    if (std::fclose(result) != 0) std::abort();
    std::printf("Actual Godot %u.%u.%u Variant boolean gate: %d checks passed\n",
                version.major, version.minor, version.patch, checks);
}
void deinitialize(void *, GDExtensionInitializationLevel) {}
} // namespace

extern "C" GDExtensionBool aether_java_boolean_test_init(
    GDExtensionInterfaceGetProcAddress get_proc,
    GDExtensionClassLibraryPtr, GDExtensionInitialization *initialization) {
#define LOAD(name, type, proc) name = reinterpret_cast<type>(get_proc(proc)); if (!name) return false
    LOAD(variant_type, GDExtensionInterfaceVariantGetType, "variant_get_type");
    LOAD(new_nil, GDExtensionInterfaceVariantNewNil, "variant_new_nil");
    LOAD(destroy_variant, GDExtensionInterfaceVariantDestroy, "variant_destroy");
    LOAD(from_type, GDExtensionInterfaceGetVariantFromTypeConstructor, "get_variant_from_type_constructor");
    LOAD(to_type, GDExtensionInterfaceGetVariantToTypeConstructor, "get_variant_to_type_constructor");
    LOAD(new_string, GDExtensionInterfaceStringNewWithUtf8Chars, "string_new_with_utf8_chars");
    LOAD(type_destructor, GDExtensionInterfaceVariantGetPtrDestructor, "variant_get_ptr_destructor");
    LOAD(godot_version, GDExtensionInterfaceGetGodotVersion, "get_godot_version");
#undef LOAD
    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
    initialization->userdata = nullptr;
    initialization->initialize = initialize;
    initialization->deinitialize = deinitialize;
    return true;
}
