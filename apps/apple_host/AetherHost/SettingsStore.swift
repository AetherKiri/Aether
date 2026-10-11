import Foundation

/// Effective, persisted preferences. Transient controls and engine state do not
/// belong here. A settings page edits a value copy until a successful save.
struct HostSettings: Codable, Equatable {
    static let schemaVersion = 1
    var version = schemaVersion
    var languageMode = "system"
    var renderer = "metal"
    var virtualControls = false
    var logs = false
    var translationModelPath = ""
    var pluginLoadMode = "krkrsdl3"
    var mockEnabled = true
    var errorDialogLogs = false

    enum Failure: Error { case unsupportedVersion, invalidValue }

    func validated() throws -> HostSettings {
        guard version == Self.schemaVersion else { throw Failure.unsupportedVersion }
        guard (["system"] + ShellLanguage.allCases.map(\.rawValue)).contains(languageMode),
              ["software", "metal"].contains(renderer),
              ["krkrsdl3", "aether_all"].contains(pluginLoadMode) else { throw Failure.invalidValue }
        return self
    }

    func normalizedForLoad() throws -> HostSettings {
        guard version == Self.schemaVersion else { throw Failure.unsupportedVersion }
        var result = self
        if !(["system"] + ShellLanguage.allCases.map(\.rawValue)).contains(languageMode) { result.languageMode = "system" }
        if !["software", "metal"].contains(renderer) { result.renderer = "metal" }
        if !["krkrsdl3", "aether_all"].contains(pluginLoadMode) { result.pluginLoadMode = "krkrsdl3" }
        return result
    }

    var language: ShellLanguage {
        ShellLanguage(rawValue: languageMode) ?? .system
    }

    var engineOptions: [(key: String, value: String)] {
        [("plugin_load_mode", pluginLoadMode), ("mock_enabled", mockEnabled ? "1" : "0"),
         ("error_dialog_logs", errorDialogLogs ? "1" : "0")]
    }
}

struct SettingsDraft {
    private(set) var original: HostSettings
    var value: HostSettings
    var isDirty: Bool { value != original }
    init(_ settings: HostSettings) { original = settings; value = settings }
    mutating func discard() { value = original }
    mutating func accept(_ settings: HostSettings) { original = settings; value = settings }
}

struct SettingsStore {
    let url: URL

    /// Migration is committed once. The legacy keys remain intact so an older
    /// build can still run; future loads exclusively use the versioned file.
    func load(defaults: UserDefaults, legacyPrefix: String) throws -> HostSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(HostSettings.self, from: Data(contentsOf: url)).normalizedForLoad()
        }
        var settings = HostSettings()
        if let language = defaults.string(forKey: legacyPrefix + "language"),
           ShellLanguage(rawValue: language) != nil { settings.languageMode = language }
        if let renderer = defaults.string(forKey: legacyPrefix + "renderer"),
           ["software", "metal"].contains(renderer) { settings.renderer = renderer }
        settings.virtualControls = defaults.bool(forKey: legacyPrefix + "virtualControls")
        settings.logs = defaults.bool(forKey: legacyPrefix + "logs")
        settings.translationModelPath = defaults.string(forKey: legacyPrefix + "translationModel") ?? ""
        try save(settings)
        return settings
    }

    func save(_ settings: HostSettings) throws {
        let validated = try settings.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
