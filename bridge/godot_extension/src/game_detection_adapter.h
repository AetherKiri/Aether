#pragma once

#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <string>
#include <vector>

namespace aether::godot_host {

godot::Dictionary InspectGame(const godot::String &path, const godot::String &probe_root);
godot::String InspectSpecialGame(const godot::String &path, const godot::String &runtime);

godot::Dictionary ResolveGameLaunch(const godot::Dictionary &request,
                                    const std::vector<std::string> &native_sessions,
                                    const godot::Callable &legacy_inspect,
                                    const godot::Callable &legacy_special_entry);

} // namespace aether::godot_host
