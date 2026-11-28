#pragma once

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace aether::godot_host {

godot::Dictionary InspectGame(const godot::String &path, const godot::String &probe_root);
godot::String InspectSpecialGame(const godot::String &path, const godot::String &runtime);

} // namespace aether::godot_host
