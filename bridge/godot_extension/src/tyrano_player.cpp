#include "tyrano_player.h"
#include "tyrano_webview.h"
#include <godot_cpp/classes/display_server.hpp>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#ifdef __ANDROID__
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/java_class.hpp>
#include <godot_cpp/classes/java_class_wrapper.hpp>
#include <godot_cpp/classes/java_object.hpp>
#endif
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {
class AetherTyranoPlayer : public Node {
    GDCLASS(AetherTyranoPlayer, Node)
    void *handle_ = nullptr;
    String error_;
#ifdef __ANDROID__
    Ref<JavaObject> android_;
#endif
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("is_supported"), &AetherTyranoPlayer::is_supported);
        ClassDB::bind_method(D_METHOD("open", "entry", "storage"), &AetherTyranoPlayer::open);
        ClassDB::bind_method(D_METHOD("close"), &AetherTyranoPlayer::close);
        ClassDB::bind_method(D_METHOD("get_error"), &AetherTyranoPlayer::get_error);
        ClassDB::bind_method(D_METHOD("set_rect", "rect", "viewport_size"), &AetherTyranoPlayer::set_rect);
        ClassDB::bind_method(D_METHOD("set_paused", "paused"), &AetherTyranoPlayer::set_paused);
        ClassDB::bind_method(D_METHOD("set_controls_frame", "frame"), &AetherTyranoPlayer::set_controls_frame);
        ClassDB::bind_method(D_METHOD("send_input", "event"), &AetherTyranoPlayer::send_input);
#ifdef DEBUG_ENABLED
        ClassDB::bind_method(D_METHOD("evaluate_script", "script"), &AetherTyranoPlayer::evaluate_script);
#endif
        ADD_SIGNAL(MethodInfo("event_received", PropertyInfo(Variant::DICTIONARY, "event")));
    }
public:
    ~AetherTyranoPlayer() override { close(); }
    bool is_supported() const {
#ifdef __APPLE__
        const String display = DisplayServer::get_singleton()->get_name();
        return display == "macOS" || display == "iOS";
#elif defined(__ANDROID__)
        return Engine::get_singleton()->has_singleton("AndroidRuntime") &&
            JavaClassWrapper::get_singleton() != nullptr;
#else
        return false;
#endif
    }
    bool open(const String &entry, const String &storage) {
        close(); error_ = "";
#ifdef __APPLE__
        auto *window = get_window();
        if (!is_supported() || !window) { error_ = "A native Apple window is required"; return false; }
        const uint64_t native = DisplayServer::get_singleton()->window_get_native_handle(
#if TARGET_OS_IPHONE
            DisplayServer::WINDOW_VIEW,
#else
            DisplayServer::WINDOW_HANDLE,
#endif
            window->get_window_id());
        char *error = nullptr;
        handle_ = aether_tyrano_open(native, entry.utf8().get_data(), storage.utf8().get_data(), &error);
        if (error) { error_ = String::utf8(error); aether_tyrano_free_string(error); }
        set_process(handle_ != nullptr);
        return handle_ != nullptr;
#elif defined(__ANDROID__)
        if (!is_supported()) { error_ = "The Android runtime is unavailable"; return false; }
        auto *wrapper = JavaClassWrapper::get_singleton();
        Ref<JavaClass> bridge = wrapper->wrap("org.aether.tyrano.TyranoHost");
        if (bridge.is_null()) { error_ = "The TyranoScript Android host was not packaged; build with build.sh android"; return false; }
        Object *runtime = Engine::get_singleton()->get_singleton("AndroidRuntime");
        const Variant activity = runtime->call("getActivity");
        android_ = bridge->call("create", activity, entry, storage);
        if (android_.is_null()) { error_ = "Could not create the Android WebView host"; return false; }
        error_ = android_->call("getError");
        if (!error_.is_empty()) { close(); return false; }
        set_process(true);
        return true;
#else
        error_ = "TyranoScript hosting requires macOS, iOS or Android";
        return false;
#endif
    }
    void close() {
        set_process(false);
#ifdef __APPLE__
        if (handle_) { aether_tyrano_close(handle_); handle_ = nullptr; }
#elif defined(__ANDROID__)
        if (android_.is_valid()) { android_->call("close"); android_.unref(); }
#endif
    }
    String get_error() const { return error_; }
    void set_rect(const Rect2 &rect, const Vector2 &viewport_size) {
#ifdef __APPLE__
        if (handle_ && viewport_size.x > 0 && viewport_size.y > 0)
            aether_tyrano_rect(handle_, rect.position.x / viewport_size.x,
                rect.position.y / viewport_size.y, rect.size.x / viewport_size.x, rect.size.y / viewport_size.y);
#elif defined(__ANDROID__)
        if (android_.is_valid() && viewport_size.x > 0 && viewport_size.y > 0)
            android_->call("setRect", double(rect.position.x / viewport_size.x),
                double(rect.position.y / viewport_size.y), double(rect.size.x / viewport_size.x), double(rect.size.y / viewport_size.y));
#endif
    }
    void set_paused(bool paused) {
#ifdef __APPLE__
        if (handle_) aether_tyrano_pause(handle_, paused);
#elif defined(__ANDROID__)
        if (android_.is_valid()) android_->call("setPaused", paused);
#endif
    }
    void set_controls_frame(const Dictionary &frame) {
        const String json = JSON::stringify(frame);
#ifdef __APPLE__
        if (handle_) aether_tyrano_controls(handle_, json.utf8().get_data());
#elif defined(__ANDROID__)
        if (android_.is_valid()) android_->call("setControlsFrame", json);
#endif
    }
    void send_input(const Dictionary &event) {
        const String json = JSON::stringify(event);
#ifdef __APPLE__
        if (handle_) aether_tyrano_input(handle_, json.utf8().get_data());
#elif defined(__ANDROID__)
        if (android_.is_valid()) android_->call("sendInput", json);
#endif
    }
    void evaluate_script(const String &script) {
#ifdef __APPLE__
        if (handle_) aether_tyrano_evaluate(handle_, script.utf8().get_data());
#elif defined(__ANDROID__)
        if (android_.is_valid()) android_->call("evaluate", script);
#endif
    }
    void _process(double) override {
#ifdef __APPLE__
        for (int i = 0; handle_ && i < 64; ++i) {
            char *event = aether_tyrano_poll(handle_);
            if (!event) break;
            const Variant value = JSON::parse_string(String::utf8(event));
            aether_tyrano_free_string(event);
            if (value.get_type() == Variant::DICTIONARY) emit_signal("event_received", value);
        }
#elif defined(__ANDROID__)
        for (int i = 0; android_.is_valid() && i < 64; ++i) {
            const String event = android_->call("poll");
            if (event.is_empty()) break;
            const Variant value = JSON::parse_string(event);
            if (value.get_type() == Variant::DICTIONARY) emit_signal("event_received", value);
        }
#endif
    }
};
void RegisterAetherTyranoPlayer() { ClassDB::register_class<AetherTyranoPlayer>(); }
}
