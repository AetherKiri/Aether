import Foundation

/// Host-side sampling switches a diagnostic profile turns on.
struct HostDiagnosticFlags: Equatable {
    var sampleFrameWork = false
    var logInputEvents = false
    var sampleSystemInfo = false

    var isEmpty: Bool { !sampleFrameWork && !logInputEvents && !sampleSystemInfo }
}

/// Godot `DIAGNOSTIC_PROFILES` catalog.
///
/// Every profile maps onto sources the Apple host really has: engine trace
/// options plus host sampling. Categories whose Godot sampling source has no
/// Apple equivalent yet are reported instead of being faked, and profiles with
/// no Apple effect at all stay disabled in the picker.
enum DiagnosticProfile: String, CaseIterable, Identifiable {
    case off, baseline, input, render, storage, script, audio, video, plugin, system, full

    var id: String { rawValue }
    var textKey: String { "profile_" + rawValue }

    /// Engine options applied before a game opens (ABI option names).
    var engineOptions: [(key: String, value: String)] {
        switch self {
        case .input: return [("input_trace", "1")]
        case .plugin: return [("plugin_trace", "1")]
        case .full: return [("input_trace", "1"), ("plugin_trace", "1"), ("trace_log", "1")]
        default: return []
        }
    }

    var hostFlags: HostDiagnosticFlags {
        switch self {
        case .baseline, .render:
            return HostDiagnosticFlags(sampleFrameWork: true)
        case .input:
            return HostDiagnosticFlags(logInputEvents: true)
        case .system:
            return HostDiagnosticFlags(sampleSystemInfo: true)
        case .full:
            return HostDiagnosticFlags(sampleFrameWork: true, logInputEvents: true, sampleSystemInfo: true)
        case .off, .storage, .script, .audio, .video, .plugin:
            return HostDiagnosticFlags()
        }
    }

    /// Godot categories this build cannot sample yet (no engine/host source).
    var unavailableCategories: [String] {
        switch self {
        case .storage: return ["storage"]
        case .script: return ["script"]
        case .audio: return ["audio"]
        case .video: return ["video"]
        case .full: return ["storage", "script", "audio", "video"]
        default: return []
        }
    }

    /// Selectable when the profile has at least one real Apple effect.
    var hasAppleSampling: Bool {
        self == .off || !engineOptions.isEmpty || !hostFlags.isEmpty
    }

    /// Godot catalog overhead class, shown next to the profile.
    var overhead: String {
        switch self {
        case .off, .baseline: return "low"
        case .full: return "high"
        default: return "medium"
        }
    }

    var summary: String {
        let options = engineOptions.map { $0.key }.sorted()
        var parts: [String] = []
        if !options.isEmpty { parts.append("engine: " + options.joined(separator: "+")) }
        if hostFlags.sampleFrameWork { parts.append("host: frame-work") }
        if hostFlags.logInputEvents { parts.append("host: input-events") }
        if hostFlags.sampleSystemInfo { parts.append("host: system/export") }
        if parts.isEmpty { parts.append("no sampling") }
        if !unavailableCategories.isEmpty {
            parts.append("unavailable: " + unavailableCategories.joined(separator: "/"))
        }
        return "\(overhead) overhead · " + parts.joined(separator: " · ")
    }

    static func normalized(_ raw: String) -> DiagnosticProfile? {
        DiagnosticProfile(rawValue: raw)
    }
}

/// Godot `DEBUG_OVERLAY_MODES`.
enum DebugOverlayMode: String, CaseIterable, Identifiable {
    case off, summary, detail
    var id: String { rawValue }
    var textKey: String { "overlay_" + rawValue }
    static func normalized(_ raw: String) -> DebugOverlayMode? { DebugOverlayMode(rawValue: raw) }
}
