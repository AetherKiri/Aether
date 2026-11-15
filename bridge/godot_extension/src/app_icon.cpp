#include "app_icon.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#ifdef __ANDROID__
#include <godot_cpp/classes/java_class.hpp>
#include <godot_cpp/classes/java_class_wrapper.hpp>
#endif
#ifdef __APPLE__
extern "C" void aether_app_icon_apply(bool astryx, const uint8_t *png, int64_t length);
#endif

namespace godot {
class AetherAppIcon : public RefCounted {
    GDCLASS(AetherAppIcon, RefCounted)
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("apply", "astryx", "png"), &AetherAppIcon::apply);
    }
public:
    void apply(bool astryx, const PackedByteArray &png) {
        if (Engine::get_singleton()->is_editor_hint()) return;
#if defined(__APPLE__)
        aether_app_icon_apply(astryx, png.ptr(), png.size());
#elif defined(__ANDROID__)
        if (!JavaClassWrapper::get_singleton() ||
            !Engine::get_singleton()->has_singleton("AndroidRuntime")) return;
        Ref<JavaClass> api = JavaClassWrapper::get_singleton()->wrap("org.aether.mobile.AppIcon");
        if (api.is_valid()) {
            Object *runtime = Engine::get_singleton()->get_singleton("AndroidRuntime");
            api->call("apply", runtime->call("getActivity"), astryx);
        }
#endif
    }
};
void RegisterAetherAppIcon() { ClassDB::register_class<AetherAppIcon>(); }
}
