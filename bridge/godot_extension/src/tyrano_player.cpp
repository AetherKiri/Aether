#include "tyrano_player.h"
#include "tyrano_webview.h"
#include <godot_cpp/classes/display_server.hpp>
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
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("is_supported"), &AetherTyranoPlayer::is_supported);
        ClassDB::bind_method(D_METHOD("open", "entry", "storage"), &AetherTyranoPlayer::open);
        ClassDB::bind_method(D_METHOD("close"), &AetherTyranoPlayer::close);
        ClassDB::bind_method(D_METHOD("get_error"), &AetherTyranoPlayer::get_error);
        ClassDB::bind_method(D_METHOD("set_rect", "rect", "viewport_size"), &AetherTyranoPlayer::set_rect);
        ClassDB::bind_method(D_METHOD("set_paused", "paused"), &AetherTyranoPlayer::set_paused);
        ClassDB::bind_method(D_METHOD("set_virtual_controls", "visible"), &AetherTyranoPlayer::set_virtual_controls);
#ifdef DEBUG_ENABLED
        ClassDB::bind_method(D_METHOD("evaluate_script", "script"), &AetherTyranoPlayer::evaluate_script);
#endif
        ADD_SIGNAL(MethodInfo("event_received", PropertyInfo(Variant::DICTIONARY, "event")));
    }
public:
    ~AetherTyranoPlayer() override { close(); }
    bool is_supported() const {
#ifdef __APPLE__
        // The UIKit bridge compiles, but mobile hosting is not advertised
        // until input, lifecycle and native-view placement are validated.
        return DisplayServer::get_singleton()->get_name() == "macOS";
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
            DisplayServer::WINDOW_HANDLE, window->get_window_id());
        char *error = nullptr;
        handle_ = aether_tyrano_open(native, entry.utf8().get_data(), storage.utf8().get_data(), &error);
        if (error) { error_ = String::utf8(error); aether_tyrano_free_string(error); }
        set_process(handle_ != nullptr);
        return handle_ != nullptr;
#else
        error_ = "TyranoScript hosting currently requires macOS";
        return false;
#endif
    }
    void close() {
        set_process(false);
#ifdef __APPLE__
        if (handle_) { aether_tyrano_close(handle_); handle_ = nullptr; }
#endif
    }
    String get_error() const { return error_; }
    void set_rect(const Rect2 &rect, const Vector2 &viewport_size) {
#ifdef __APPLE__
        if (handle_ && viewport_size.x > 0 && viewport_size.y > 0)
            aether_tyrano_rect(handle_, rect.position.x / viewport_size.x,
                rect.position.y / viewport_size.y, rect.size.x / viewport_size.x, rect.size.y / viewport_size.y);
#endif
    }
    void set_paused(bool paused) {
#ifdef __APPLE__
        if (handle_) aether_tyrano_pause(handle_, paused);
#endif
    }
    void set_virtual_controls(bool visible) {
#ifdef __APPLE__
        if (handle_) aether_tyrano_controls(handle_, visible);
#endif
    }
    void evaluate_script(const String &script) {
#ifdef __APPLE__
        if (handle_) aether_tyrano_evaluate(handle_, script.utf8().get_data());
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
#endif
    }
};
void RegisterAetherTyranoPlayer() { ClassDB::register_class<AetherTyranoPlayer>(); }
}
