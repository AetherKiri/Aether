import Foundation

/// Godot's advanced tools (`_set_advanced_tool`): session-only engine options
/// that are never written to the settings file. `plugin_trace` and `trace_log`
/// expire after 30 seconds (`ADVANCED_TRACE_TIMEOUT_MS`) so an expensive trace
/// cannot be left on by accident.
struct TransientDiagnosticsTools: Equatable {
    enum Option: String, CaseIterable, Identifiable {
        case pluginTrace = "plugin_trace"
        case traceLog = "trace_log"
        case consoleLogFile = "console_log_file"
        case exportScripts = "export_scripts"

        var id: String { rawValue }
        var textKey: String { "advanced_" + rawValue }
        var descKey: String { "advanced_" + rawValue + "_desc" }
        var engineValue: String { "1" }
        /// Only the tracing options expire, like Godot.
        var expires: Bool { self == .pluginTrace || self == .traceLog }
    }

    static let traceTimeout: TimeInterval = 30

    private(set) var enabled: Set<Option> = []
    private var deadlines: [Option: TimeInterval] = [:]

    func isEnabled(_ option: Option) -> Bool { enabled.contains(option) }

    func deadline(_ option: Option) -> TimeInterval? { deadlines[option] }

    func remainingSeconds(_ option: Option, now: TimeInterval) -> Int? {
        guard let deadline = deadlines[option], enabled.contains(option) else { return nil }
        return max(0, Int((deadline - now).rounded(.up)))
    }

    /// `now` is a monotonic host time in seconds.
    mutating func set(_ option: Option, enabled on: Bool, now: TimeInterval) {
        if on {
            enabled.insert(option)
            deadlines[option] = option.expires ? now + Self.traceTimeout : nil
        } else {
            enabled.remove(option)
            deadlines[option] = nil
        }
    }

    /// Expires the tracing options. Returns the options that must now be turned
    /// off in the engine (already cleared from this snapshot).
    mutating func expire(now: TimeInterval) -> [Option] {
        let expired = enabled
            .filter { deadlines[$0].map { now >= $0 } ?? false }
            .sorted { $0.rawValue < $1.rawValue }
        for option in expired { set(option, enabled: false, now: now) }
        return expired
    }

    var engineOptions: [(key: String, value: String)] {
        enabled.sorted { $0.rawValue < $1.rawValue }.map { ($0.rawValue, $0.engineValue) }
    }

    /// Godot `_advanced_snapshot`: flags plus remaining seconds for tracing.
    func snapshot(now: TimeInterval) -> [String: String] {
        var result: [String: String] = [:]
        for option in Option.allCases {
            result[option.rawValue] = isEnabled(option) ? "1" : "0"
            if let remaining = remainingSeconds(option, now: now) {
                result[option.rawValue + "_remaining_sec"] = String(remaining)
            }
        }
        return result
    }

    mutating func reset() {
        enabled = []
        deadlines = [:]
    }
}
