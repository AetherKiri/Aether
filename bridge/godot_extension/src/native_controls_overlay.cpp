#include "native_controls_overlay.h"
#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rect2.hpp>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

namespace godot {
// Only composites pixels and routes native hit tests. The Control tree,
// gestures and actions all belong to game_virtual_controls.gd.
class AetherNativeControls : public Node {
    GDCLASS(AetherNativeControls, Node)
    void *handle_ = nullptr;
    Rect2 rect_{0, 0, 1, 1};
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("is_supported"), &AetherNativeControls::is_supported);
        ClassDB::bind_method(D_METHOD("present", "image", "regions"), &AetherNativeControls::present);
        ClassDB::bind_method(D_METHOD("set_rect", "rect", "viewport_size"), &AetherNativeControls::set_rect);
        ClassDB::bind_method(D_METHOD("set_visible", "visible"), &AetherNativeControls::set_visible);
        ClassDB::bind_method(D_METHOD("close"), &AetherNativeControls::close);
    }
public:
    ~AetherNativeControls() override { close(); }
    bool is_supported() const {
#ifdef __APPLE__
        const String display = DisplayServer::get_singleton()->get_name();
        return display == "macOS" || display == "iOS";
#else
        return false;
#endif
    }
    void present(const Ref<Image> &image, const Array &regions) {
#ifdef __APPLE__
        if (image.is_null() || image->is_empty() || !is_supported() || !get_window()) return;
        if (!handle_) {
            const uint64_t window = DisplayServer::get_singleton()->window_get_native_handle(
#if TARGET_OS_IPHONE
                DisplayServer::WINDOW_VIEW,
#else
                DisplayServer::WINDOW_HANDLE,
#endif
                get_window()->get_window_id());
            handle_ = aether_controls_open(window);
        }
        if (!handle_) return;
        Ref<Image> rgba = image;
        if (rgba->get_format() != Image::FORMAT_RGBA8) {
            rgba = image->duplicate();
            rgba->convert(Image::FORMAT_RGBA8);
        }
        const PackedByteArray pixels = rgba->get_data();
        const String json = JSON::stringify(regions);
        aether_controls_rect(handle_, rect_.position.x, rect_.position.y, rect_.size.x, rect_.size.y);
        aether_controls_present(handle_, pixels.ptr(), rgba->get_width(), rgba->get_height(), json.utf8().get_data());
#endif
    }
    void set_rect(const Rect2 &rect, const Vector2 &viewport_size) {
        if (viewport_size.x <= 0 || viewport_size.y <= 0) return;
        rect_ = Rect2(rect.position / viewport_size, rect.size / viewport_size);
#ifdef __APPLE__
        if (handle_) aether_controls_rect(handle_, rect_.position.x, rect_.position.y, rect_.size.x, rect_.size.y);
#endif
    }
    void set_visible(bool visible) {
#ifdef __APPLE__
        if (handle_) aether_controls_visible(handle_, visible);
#endif
    }
    void close() {
#ifdef __APPLE__
        if (handle_) { aether_controls_close(handle_); handle_ = nullptr; }
#endif
    }
};
void RegisterAetherNativeControls() { ClassDB::register_class<AetherNativeControls>(); }
}
