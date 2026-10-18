#include "renpy_native.h"
#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rect2.hpp>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#include <cstdlib>
#if defined(__APPLE__) || (defined(__linux__) && !defined(__ANDROID__))
#define AETHER_RENPY_C_HOST 1
#endif
#ifdef __ANDROID__
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/java_class.hpp>
#include <godot_cpp/classes/java_class_wrapper.hpp>
#include <godot_cpp/classes/java_object.hpp>
#endif

namespace godot {
    class AetherRenpyNativePlayer : public Node {
        GDCLASS(AetherRenpyNativePlayer, Node)
        void *handle_ = nullptr;
        String error_;
        bool paused_ = false;
#ifdef __ANDROID__
        Ref<JavaObject> android_;
        static Variant activity() {
            return Engine::get_singleton()
                ->get_singleton("AndroidRuntime")
                ->call("getActivity");
        }
        static Ref<JavaClass> android_bridge() {
            return JavaClassWrapper::get_singleton()->wrap(
                "org.aether.renpy.RenpyHost");
        }
#endif
    protected:
        static void _bind_methods() {
            ClassDB::bind_method(D_METHOD("is_supported"),
                                 &AetherRenpyNativePlayer::is_supported);
            ClassDB::bind_method(D_METHOD("prepare_runtime"),
                                 &AetherRenpyNativePlayer::prepare_runtime);
            ClassDB::bind_method(
                D_METHOD("open", "sdk", "manifest", "bootstrap", "greenlet"),
                &AetherRenpyNativePlayer::open);
            ClassDB::bind_method(D_METHOD("close"),
                                 &AetherRenpyNativePlayer::close);
            ClassDB::bind_method(D_METHOD("get_error"),
                                 &AetherRenpyNativePlayer::get_error);
            ClassDB::bind_method(D_METHOD("is_embedded"),
                                 &AetherRenpyNativePlayer::is_embedded);
            ClassDB::bind_method(D_METHOD("set_paused", "paused"),
                                 &AetherRenpyNativePlayer::set_paused);
            ClassDB::bind_method(D_METHOD("send_input", "event"),
                                 &AetherRenpyNativePlayer::send_input);
            ClassDB::bind_method(D_METHOD("set_rect", "rect", "viewport_size"),
                                 &AetherRenpyNativePlayer::set_rect);
            ADD_SIGNAL(
                MethodInfo("failed", PropertyInfo(Variant::STRING, "message")));
        }

    public:
        ~AetherRenpyNativePlayer() override { close(); }
        bool is_supported() const {
#if defined(__APPLE__)
            const String display = DisplayServer::get_singleton()->get_name();
            return display == "macOS" || display == "iOS";
#elif defined(__ANDROID__)
            if(!Engine::get_singleton()->has_singleton("AndroidRuntime") ||
               !JavaClassWrapper::get_singleton())
                return false;
            Ref<JavaClass> bridge = android_bridge();
            return bridge.is_valid() &&
                bool(bridge->call("isSupported", activity()));
#elif defined(__linux__)
            return DisplayServer::get_singleton()->get_name() == "X11";
#else
            return false;
#endif
        }
        String prepare_runtime() {
#ifdef __ANDROID__
            if(!is_supported())
                return "";
            Ref<JavaClass> bridge = android_bridge();
            const String sdk = bridge->call("prepareRuntime", activity());
            error_ = bridge->call("getPreparationError");
            return sdk;
#else
            return "";
#endif
        }
        bool open(const String &sdk, const String &manifest,
                  const String &bootstrap, const String &greenlet) {
            close();
            error_ = "";
#ifdef AETHER_RENPY_C_HOST
            if(!is_supported() || !get_window()) {
                error_ = "A native Apple or X11 window is required";
                return false;
            }
            const uint64_t window =
                DisplayServer::get_singleton()->window_get_native_handle(
#if defined(__APPLE__) && TARGET_OS_IPHONE
                    DisplayServer::WINDOW_VIEW,
#else
                    DisplayServer::WINDOW_HANDLE,
#endif
                    get_window()->get_window_id());
            char *error = nullptr;
            handle_ = aether_renpy_native_open(
                window, sdk.utf8().get_data(), manifest.utf8().get_data(),
                bootstrap.utf8().get_data(), greenlet.utf8().get_data(),
                &error);
            if(error) {
                error_ = String::utf8(error);
                std::free(error);
            }
            set_process(handle_ != nullptr);
            return handle_ != nullptr;
#elif defined(__ANDROID__)
            if(!is_supported()) {
                error_ = "The native Ren'Py Android host was not packaged";
                return false;
            }
            android_ = android_bridge()->call("create", activity(), sdk,
                                              manifest, bootstrap);
            if(android_.is_null()) {
                error_ = "Could not create the native SDL Surface host";
                return false;
            }
            error_ = android_->call("getError");
            if(!error_.is_empty()) {
                close();
                return false;
            }
            set_process(true);
            return true;
#else
            error_ = "This platform has no native Ren'Py host";
            return false;
#endif
        }
        void close() {
            set_process(false);
#ifdef AETHER_RENPY_C_HOST
            if(handle_)
                aether_renpy_native_close(handle_);
#elif defined(__ANDROID__)
            if(android_.is_valid()) {
                android_->call("close");
                android_.unref();
            }
#endif
            handle_ = nullptr;
        }
        String get_error() const {
#ifdef __ANDROID__
            if(error_.is_empty() && android_.is_valid())
                return android_->call("getError");
#endif
            return error_;
        }
        bool is_embedded() const {
#ifdef AETHER_RENPY_C_HOST
            return handle_ && aether_renpy_native_is_embedded(handle_);
#elif defined(__ANDROID__)
            return android_.is_valid() && bool(android_->call("isEmbedded"));
#else
            return false;
#endif
        }
        void set_paused(bool value) {
            paused_ = value;
#ifdef AETHER_RENPY_C_HOST
            if(handle_)
                aether_renpy_native_pause(handle_, value);
#elif defined(__ANDROID__)
            if(android_.is_valid())
                android_->call("setPaused", value);
#endif
        }
        void set_rect(const Rect2 &rect, const Vector2 &size) {
#ifdef AETHER_RENPY_C_HOST
            if(handle_ && size.x > 0 && size.y > 0)
                aether_renpy_native_rect(
                    handle_, rect.position.x / size.x, rect.position.y / size.y,
                    rect.size.x / size.x, rect.size.y / size.y);
#elif defined(__ANDROID__)
            if(android_.is_valid() && size.x > 0 && size.y > 0)
                android_->call("setRect", double(rect.position.x / size.x),
                               double(rect.position.y / size.y),
                               double(rect.size.x / size.x),
                               double(rect.size.y / size.y));
#endif
        }
        void send_input(const Dictionary &event) {
#ifdef AETHER_RENPY_C_HOST
            if(handle_ && !paused_)
                aether_renpy_native_input(
                    handle_, JSON::stringify(event).utf8().get_data());
#elif defined(__ANDROID__)
            if(android_.is_valid() && !paused_)
                android_->call("sendInput", JSON::stringify(event));
#endif
        }
        void _process(double) override {
#ifdef AETHER_RENPY_C_HOST
            if(handle_ && !paused_ && !aether_renpy_native_step(handle_)) {
                error_ =
                    "The native Ren'Py host failed while processing a frame";
                set_process(false);
                emit_signal("failed", error_);
            }
#elif defined(__ANDROID__)
            const String error = get_error();
            if(!error.is_empty()) {
                set_process(false);
                emit_signal("failed", error);
            }
#endif
        }
    };
    void RegisterAetherRenpyNativePlayer() {
        ClassDB::register_class<AetherRenpyNativePlayer>();
    }
} // namespace godot
