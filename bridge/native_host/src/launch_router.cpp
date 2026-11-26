#include "aether/native_host/launch_router.h"

#include "path_utils.h"
#include "engine_runtime_provider.h"

#include <algorithm>
#include <utility>

namespace aether::native_host {
namespace {
namespace detection = game_detection;
using namespace detection::paths;

bool Includes(const std::vector<std::string> &items, const std::string &value) {
    return std::find(items.begin(), items.end(), value) != items.end();
}

bool DirectoryRuntime(std::string_view runtime) {
    constexpr std::string_view directory_runtimes[] = {
        "advhd", "renpy", "artemis", "exhibit", "bgi", "escude", "entisgls",
        "catsystem2", "mages", "n2system", "minori", "cmvs", "onscripter",
        "yuris", "siglus", "softpal", "tyranoscript", "wa2", "xsystem4",
        "xsystem35", "system3", "systemc",
    };
    return std::find(std::begin(directory_runtimes), std::end(directory_runtimes), runtime)
        != std::end(directory_runtimes);
}

std::string Slashes(std::string path) {
    std::replace(path.begin(), path.end(), '\\', '/');
    return path;
}

bool SupportedFile(const detection::Files &files, std::string_view path) {
    const auto extension = files.Lower(Extension(path));
    return extension == "exe" || extension == "xp3" || extension == "hcb";
}

std::string RelativeEntry(const detection::Files &files, const std::string &raw) {
    const auto path = Slashes(raw);
    if (Trim(path).empty() || path.front() == '/' || path.find(":/") != path.npos) {
        return {};
    }
    std::vector<std::string_view> components;
    std::string_view rest = path;
    while (!rest.empty()) {
        const auto slash = rest.find('/');
        const auto component = rest.substr(0, slash);
        if (component == "..") {
            if (components.empty()) return {};
            components.pop_back();
        } else if (!component.empty() && component != ".") {
            components.push_back(component);
        }
        if (slash == rest.npos) break;
        rest.remove_prefix(slash + 1);
    }
    std::string relative;
    for (const auto component : components) {
        relative = Join(relative, component);
    }
    return SupportedFile(files, relative) ? relative : std::string{};
}

std::string Root(const detection::Files &files, const std::string &path) {
    return files.FileExists(path) ? Parent(path) : path;
}

detection::Result Inspect(const LaunchEnvironment &environment, const std::string &root) {
    if (environment.inspect) return environment.inspect(root);
    auto result = detection::Inspect(environment.files, root);
    detection::ApplyProviderProbes(result, root);
    return result;
}

std::string StartupScript(const LaunchEnvironment &environment, const LaunchRequest &request,
                          const LaunchRoute &route, const std::string &relative) {
    std::string script{Trim(request.startup_script)};
    if (request.source != LaunchSource::Probe && script.empty() && route.runtime == "entisgls") {
        script = relative;
    }
    if (!script.empty()) {
        return script.front() == '/' ? script : Join(route.entry, script);
    }
    if (request.source == LaunchSource::Probe || route.runtime != "yuris") return {};
    constexpr std::string_view candidates[] = {
        "data/script/UserScript/SCENARIO_START.txt", "data/script/UserScript/SCENARIO_START.yst",
        "data/script/userscript/SCENARIO_START.txt", "data/script/userscript/SCENARIO_START.yst",
        "data/script/UserScript/start.txt", "data/script/UserScript/start.yst",
        "data/script/userscript/start.txt", "data/script/userscript/start.yst",
    };
    for (const auto candidate : candidates) {
        auto path = Join(route.entry, candidate);
        if (environment.files.FileExists(path)) return path;
    }
    return {};
}

LaunchRoute DedicatedRoute(const LaunchEnvironment &environment, LaunchRoute route,
                           const std::string &path) {
    route.player = route.runtime;
    const auto globalize = [&](const std::string &value) {
        return environment.globalize ? environment.globalize(value) : value;
    };
    if (route.runtime == "flash") {
        route.entry = globalize(path);
        route.root = Parent(route.entry);
    } else {
        route.root = globalize(route.root);
        if (environment.special_entry) {
            route.entry = environment.special_entry(route.root, route.runtime);
        } else if (route.runtime == "renpy") {
            route.entry = detection::RenpyDirectory(environment.files, route.root);
        } else {
            route.entry = detection::TyranoEntry(environment.files, route.root);
        }
        if (route.entry.empty()) {
            route.reason = LaunchReason::InvalidProject;
            return route;
        }
    }
    if (!Includes(environment.capabilities.dedicated_players, route.player)) {
        route.reason = LaunchReason::PlayerUnavailable;
    } else {
        route.host = LaunchHost::Dedicated;
    }
    return route;
}
} // namespace

std::vector<std::string> RegisteredLaunchProviders() {
    std::vector<std::string> ids;
    const auto count = engine_get_runtime_provider_count();
    std::vector<char> buffer(64);
    for (uint32_t index = 0; index < count; ++index) {
        uint32_t size = 0;
        // Registry entries are append-only and the ABI does not limit IDs.
        while (engine_get_runtime_provider_id(index, buffer.data(), buffer.size(), &size) != ENGINE_RESULT_OK) {
            buffer.resize(buffer.size() * 2);
        }
        ids.emplace_back(buffer.data(), size);
    }
    return ids;
}

LaunchRoute ResolveLaunch(const LaunchEnvironment &environment, const LaunchRequest &request) {
    LaunchRoute route;
    const auto &files = environment.files;
    const auto path = Slashes(request.path);
    if (Trim(path).empty()) {
        route.reason = LaunchReason::EmptyPath;
        return route;
    }
    route.root = Root(files, path);
    route.detected_runtime = request.source == LaunchSource::Flash ? "flash" : Inspect(environment, route.root).engine;
    route.runtime = route.detected_runtime;
    if (request.source == LaunchSource::Flash ||
        (request.source == LaunchSource::Library && (route.runtime == "renpy" || route.runtime == "tyranoscript"))) {
        return DedicatedRoute(environment, std::move(route), path);
    }

    route.entry = path;
    const auto relative = RelativeEntry(files, request.selected_file);
    if (request.source == LaunchSource::Library && !DirectoryRuntime(route.runtime)) {
        const auto configured = Trim(request.selected_file);
        if (!configured.empty()) {
            if (!SupportedFile(files, configured)) {
                route.reason = LaunchReason::UnsupportedEntry;
                return route;
            }
            if (relative.empty()) {
                route.reason = LaunchReason::EntryOutsideGame;
                return route;
            }
            route.entry = Join(path, relative);
            if (!files.FileExists(route.entry)) {
                route.reason = LaunchReason::EntryMissing;
                route.error_entry = relative;
                return route;
            }
        } else if (route.runtime == "rfvp" && files.DirectoryExists(path)) {
            const auto hcb = detection::HcbEntry(files, path);
            if (!hcb.empty()) route.entry = Join(path, hcb);
        }
        const auto entry_root = Root(files, route.entry);
        // The existing direct-open path detects again for a hand-picked file
        // in a different directory. Keep that behavior for nested entries.
        if (entry_root != route.root) {
            route.root = entry_root;
            route.runtime = Inspect(environment, route.root).engine;
        }
    }
    if (DirectoryRuntime(route.runtime)) route.entry = route.root;

    route.player = "runtime";
    route.engine_option = route.runtime == "kirikiri" || route.runtime == "artemis" ||
                          route.runtime == "renpy" || route.runtime == "tyranoscript" ? "auto" : route.runtime;
    if (route.engine_option == "auto") {
        route.provider = ProviderStatus::Deferred;
    } else {
        route.provider = Includes(environment.capabilities.providers, route.engine_option)
            ? ProviderStatus::Registered : ProviderStatus::Missing;
    }
    route.native_requested = request.host == HostPreference::Native ||
                              (request.host == HostPreference::Automatic && request.prerelease);
    if (!environment.capabilities.common_player) {
        route.reason = LaunchReason::PlayerUnavailable;
    } else if (route.provider == ProviderStatus::Missing) {
        route.reason = LaunchReason::ProviderMissing;
    } else if (route.native_requested && Includes(environment.capabilities.native_sessions, route.runtime)) {
        route.host = LaunchHost::Native;
    } else {
        route.host = LaunchHost::Legacy;
        if (route.native_requested) route.reason = LaunchReason::NativeUnavailable;
        else if (request.host == HostPreference::Legacy) route.reason = LaunchReason::LegacyRequested;
        else route.reason = LaunchReason::StableChannel;
    }
    route.startup_script = StartupScript(environment, request, route, relative);
    return route;
}

const char *LaunchHostName(LaunchHost host) {
    switch (host) {
        case LaunchHost::Native: return "native";
        case LaunchHost::Legacy: return "legacy";
        case LaunchHost::Dedicated: return "dedicated";
        case LaunchHost::None: return "unavailable";
    }
    return "unavailable";
}

const char *ProviderStatusName(ProviderStatus status) {
    switch (status) {
        case ProviderStatus::NotApplicable: return "not_applicable";
        case ProviderStatus::Deferred: return "deferred";
        case ProviderStatus::Registered: return "registered";
        case ProviderStatus::Missing: return "missing";
    }
    return "not_applicable";
}

const char *LaunchReasonName(LaunchReason reason) {
    switch (reason) {
        case LaunchReason::None: return "";
        case LaunchReason::StableChannel: return "stable_channel";
        case LaunchReason::LegacyRequested: return "legacy_requested";
        case LaunchReason::NativeUnavailable: return "native_session_unavailable";
        case LaunchReason::ProviderMissing: return "provider_missing";
        case LaunchReason::PlayerUnavailable: return "player_unavailable";
        case LaunchReason::EmptyPath: return "empty_path";
        case LaunchReason::UnsupportedEntry: return "unsupported_entry";
        case LaunchReason::EntryOutsideGame: return "entry_outside_game";
        case LaunchReason::EntryMissing: return "entry_missing";
        case LaunchReason::InvalidProject: return "invalid_project";
    }
    return "";
}

} // namespace aether::native_host
