#pragma once

#include "aether/game_detection.h"

namespace aether::native_host {

enum class LaunchSource { Library, Direct, Probe, Flash };
enum class HostPreference { Automatic, Native, Legacy };
enum class LaunchHost { None, Native, Legacy, Dedicated };
enum class ProviderStatus { NotApplicable, Deferred, Registered, Missing };
enum class LaunchReason {
    None,
    StableChannel,
    LegacyRequested,
    NativeUnavailable,
    ProviderMissing,
    PlayerUnavailable,
    EmptyPath,
    UnsupportedEntry,
    EntryOutsideGame,
    EntryMissing,
    InvalidProject,
};

struct LaunchRequest {
    LaunchSource source = LaunchSource::Library;
    std::string path;
    std::string selected_file;
    std::string startup_script;
    HostPreference host = HostPreference::Automatic;
    bool prerelease = false;
};

struct LaunchCapabilities {
    std::vector<std::string> providers;
    std::vector<std::string> native_sessions;
    std::vector<std::string> dedicated_players;
    bool common_player = false;
};

// Adapter hooks for a legacy detector or a virtual filesystem. With no
// overrides the router uses the shared detector and ordinary path semantics.
struct LaunchEnvironment {
    const game_detection::Files &files;
    const LaunchCapabilities &capabilities;
    std::function<game_detection::Result(const std::string &root)> inspect;
    std::function<std::string(const std::string &path, const std::string &runtime)> special_entry;
    std::function<std::string(const std::string &path)> globalize;
};

struct LaunchRoute {
    std::string detected_runtime;
    std::string runtime;
    std::string engine_option;
    std::string player;
    std::string root;
    // Dedicated TyranoScript and Ren’Py entries are relative to root.
    std::string entry;
    std::string startup_script;
    ProviderStatus provider = ProviderStatus::NotApplicable;
    bool native_requested = false;
    LaunchHost host = LaunchHost::None;
    LaunchReason reason = LaunchReason::None;
    std::string error_entry;
};

std::vector<std::string> RegisteredLaunchProviders();
LaunchRoute ResolveLaunch(const LaunchEnvironment &environment, const LaunchRequest &request);
const char *LaunchHostName(LaunchHost host);
const char *ProviderStatusName(ProviderStatus status);
const char *LaunchReasonName(LaunchReason reason);

} // namespace aether::native_host
