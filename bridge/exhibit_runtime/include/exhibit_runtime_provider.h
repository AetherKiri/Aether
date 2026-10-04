#pragma once

// The Godot GPU callback tables (TVPGodotGpuBridgeCallbacks /
// TVPGodotGpuBatchCallbacks) are deliberately not forward-declared yet: a
// RegisterGpuBridge entry point lands with the GPU compositing step, and
// this provider stays CPU-only (software surface -> read_frame_rgba) until
// then.

namespace aetherkiri::exhibit {
    void RegisterRuntimeProvider();
}
