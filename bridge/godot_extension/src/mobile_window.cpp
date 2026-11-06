#include "mobile_window.h"
#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#ifdef __ANDROID__
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/java_class.hpp>
#include <godot_cpp/classes/java_class_wrapper.hpp>
#endif

namespace godot {
class AetherMobileWindow : public Node {
    GDCLASS(AetherMobileWindow, Node)
    void *handle_ = nullptr;
#ifdef __ANDROID__
    static Ref<JavaClass> bridge() {
        if (!JavaClassWrapper::get_singleton() ||
            !Engine::get_singleton()->has_singleton("AndroidRuntime")) return {};
        return JavaClassWrapper::get_singleton()->wrap("org.aether.mobile.MobileWindow");
    }
    static Variant activity() {
        return Engine::get_singleton()->get_singleton("AndroidRuntime")->call("getActivity");
    }
#endif
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("configure", "game_active", "pip_enabled"), &AetherMobileWindow::configure);
        ClassDB::bind_method(D_METHOD("is_supported"), &AetherMobileWindow::is_supported);
        ClassDB::bind_method(D_METHOD("is_in_picture_in_picture"), &AetherMobileWindow::is_in_picture_in_picture);
    }
public:
    ~AetherMobileWindow() override {
#if defined(__APPLE__) && TARGET_OS_IPHONE
        if (handle_) aether_mobile_window_close(handle_);
#endif
    }
    void configure(bool game_active, bool pip_enabled) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
        if (!handle_ && get_window()) {
            handle_ = aether_mobile_window_open(DisplayServer::get_singleton()->window_get_native_handle(
                DisplayServer::WINDOW_VIEW, get_window()->get_window_id()));
        }
        if (handle_) aether_mobile_window_configure(handle_, game_active, pip_enabled);
#elif defined(__ANDROID__)
        Ref<JavaClass> api = bridge();
        if (api.is_valid()) api->call("configure", activity(), game_active, pip_enabled);
#endif
    }
    bool is_supported() const {
#if defined(__APPLE__) && TARGET_OS_IPHONE
        return handle_ && aether_mobile_window_supported(handle_);
#elif defined(__ANDROID__)
        Ref<JavaClass> api = bridge();
        return api.is_valid() && bool(api->call("isSupported", activity()));
#else
        return false;
#endif
    }
    bool is_in_picture_in_picture() const {
#if defined(__APPLE__) && TARGET_OS_IPHONE
        return handle_ && aether_mobile_window_in_pip(handle_);
#elif defined(__ANDROID__)
        Ref<JavaClass> api = bridge();
        return api.is_valid() && bool(api->call("isInPictureInPicture", activity()));
#else
        return false;
#endif
    }
};
void RegisterAetherMobileWindow() { ClassDB::register_class<AetherMobileWindow>(); }
}
