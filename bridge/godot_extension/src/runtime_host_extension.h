#pragma once

#include "engine_api.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <functional>
#include <memory>

// Optional package-owned platform adapters. Engine formats and command
// protocols remain in the package; the application supplies host services.
struct RuntimeHostServices {
    godot::Node *owner = nullptr;
    godot::String storage_path;
    std::function<godot::String()> game_root;
    std::function<int(const godot::String &, const godot::String &)> respond;
    std::function<void(const godot::String &, const godot::String &)> emit;
    std::function<bool(const godot::String &)> media_open;
    std::function<int()> media_play;
    std::function<void()> media_close;
    std::function<godot::Dictionary()> media_state;
    std::function<godot::Ref<godot::Texture2D>()> media_texture;
};

class RuntimeHostExtension {
public:
    virtual ~RuntimeHostExtension() = default;
    virtual void Destroy() = 0;
    virtual void Reset(bool children_alive) = 0;
    virtual bool Request(const godot::String &, const godot::String &) = 0;
    virtual void Tick(double delta_seconds) = 0;
    virtual bool ResponseNeedsTick(const godot::String &) const = 0;
    virtual bool SkipMedia() = 0;
    virtual godot::Ref<godot::Texture2D> FrameOverride() = 0;
    virtual bool HasComposite() const = 0;
    virtual void Composite(godot::PackedByteArray &, const engine_frame_desc_t &) = 0;
};

struct RuntimeHostExtensionDeleter {
    void operator()(RuntimeHostExtension *extension) const {
        if (extension != nullptr) extension->Destroy();
    }
};
using RuntimeHostExtensionPtr =
    std::unique_ptr<RuntimeHostExtension, RuntimeHostExtensionDeleter>;

#if defined(AETHERKIRI_INTERNAL_RUNTIME_HOST)
RuntimeHostExtensionPtr CreateAetherInternalRuntimeHost(const RuntimeHostServices &services);
#endif
