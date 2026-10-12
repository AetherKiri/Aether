import Foundation

/// Effective, persisted preferences. Transient controls and engine state do not
/// belong here. A settings page edits a value copy until a successful save.
struct HostSettings: Codable, Equatable {
    static let schemaVersion = 9
    /// Godot's dev builds default to `baseline` diagnostics; release is off.
    static var defaultDiagnosticProfile: String {
        #if DEBUG
        return "baseline"
        #else
        return "off"
        #endif
    }
    var version = schemaVersion
    var languageMode = "system"
    var theme = "classic"
    var renderer = "metal"
    var canvasMode = "game"
    var outputResolution = "1080p"
    var upscaleAlgorithm = "bicubic"
    var fpsLimitEnabled = false
    var targetFPS = FrameScheduler.defaultTargetFPS
    var diagnosticProfile = HostSettings.defaultDiagnosticProfile
    var debugOverlayMode = "off"
    var virtualControlMode = "mouse"
    var virtualControlMenuEnabled = true
    var virtualControlKeyboardOpacity = 1.0
    var frameEnhancementKind = "off"
    var frameEnhancementPreset = EnhancementPreset.defaultPreset.id
    var frameEnhancementChain: [String] = EnhancementPreset.defaultPreset.steps.map(\.rawValue)
    var frameEnhancementAmount = 0.5
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
              ShellTheme(rawValue: theme) != nil,
              ["software", "metal"].contains(renderer),
              CanvasMode(rawValue: canvasMode) != nil, OutputResolution(rawValue: outputResolution) != nil,
              SamplingAlgorithm.normalized(upscaleAlgorithm) != nil,
              FrameScheduler.normalizedTarget(targetFPS) != nil,
              DiagnosticProfile.normalized(diagnosticProfile) != nil,
              DebugOverlayMode.normalized(debugOverlayMode) != nil,
              VirtualControlMode.normalized(virtualControlMode) != nil,
              virtualControlKeyboardOpacity.isFinite,
              (VirtualControlOpacity.minimum...VirtualControlOpacity.maximum).contains(virtualControlKeyboardOpacity),
              FrameEnhancementKind(rawValue: frameEnhancementKind) != nil,
              EnhancementPreset.normalized(frameEnhancementPreset) != nil,
              frameEnhancementKind != FrameEnhancementKind.custom.rawValue
                || FrameEnhancementChain.normalized(frameEnhancementChain) != nil,
              frameEnhancementAmount.isFinite,
              FrameEnhancementKernel.amountRange.contains(frameEnhancementAmount),
              ["krkrsdl3", "aether_all"].contains(pluginLoadMode) else { throw Failure.invalidValue }
        var result = self
        result.upscaleAlgorithm = SamplingAlgorithm.normalized(upscaleAlgorithm)!.rawValue
        result.virtualControlKeyboardOpacity = VirtualControlOpacity.normalized(virtualControlKeyboardOpacity)
        result.frameEnhancementAmount = Self.normalizedEnhancementAmount(frameEnhancementAmount)
        return result
    }

    func normalizedForLoad() throws -> HostSettings {
        guard (1...Self.schemaVersion).contains(version) else { throw Failure.unsupportedVersion }
        var result = self
        result.version = Self.schemaVersion
        if ShellTheme(rawValue: theme) == nil { result.theme = "classic" }
        if !(["system"] + ShellLanguage.allCases.map(\.rawValue)).contains(languageMode) { result.languageMode = "system" }
        if !["software", "metal"].contains(renderer) { result.renderer = "metal" }
        if !["krkrsdl3", "aether_all"].contains(pluginLoadMode) { result.pluginLoadMode = "krkrsdl3" }
        if CanvasMode(rawValue: canvasMode) == nil { result.canvasMode = "game" }
        if OutputResolution(rawValue: outputResolution) == nil { result.outputResolution = "1080p" }
        if let normalized = SamplingAlgorithm.normalized(upscaleAlgorithm) {
            result.upscaleAlgorithm = normalized.rawValue
        } else {
            result.upscaleAlgorithm = "bicubic"
        }
        if FrameScheduler.normalizedTarget(targetFPS) == nil { result.targetFPS = FrameScheduler.defaultTargetFPS }
        if DiagnosticProfile.normalized(diagnosticProfile) == nil { result.diagnosticProfile = Self.defaultDiagnosticProfile }
        if DebugOverlayMode.normalized(debugOverlayMode) == nil { result.debugOverlayMode = "off" }
        if VirtualControlMode.normalized(virtualControlMode) == nil { result.virtualControlMode = "mouse" }
        result.virtualControlKeyboardOpacity = VirtualControlOpacity.normalized(virtualControlKeyboardOpacity)
        if FrameEnhancementKind(rawValue: frameEnhancementKind) == nil { result.frameEnhancementKind = "off" }
        if EnhancementPreset.normalized(frameEnhancementPreset) == nil {
            result.frameEnhancementPreset = EnhancementPreset.defaultPreset.id
        }
        if result.frameEnhancementKind == FrameEnhancementKind.custom.rawValue,
           FrameEnhancementChain.normalized(frameEnhancementChain) == nil {
            result.frameEnhancementKind = "off"
        }
        if let chain = FrameEnhancementChain.normalized(frameEnhancementChain) {
            result.frameEnhancementChain = chain.map(\.rawValue)
        }
        result.frameEnhancementAmount = Self.normalizedEnhancementAmount(frameEnhancementAmount)
        return result
    }

    /// Godot's enhancement slider snaps to 0.05 steps.
    static func normalizedEnhancementAmount(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        let clamped = min(FrameEnhancementKernel.amountRange.upperBound,
                          max(FrameEnhancementKernel.amountRange.lowerBound, value))
        let steps = (clamped / 0.05).rounded()
        return (steps * 0.05 * 1000).rounded() / 1000
    }

    var profile: DiagnosticProfile { DiagnosticProfile.normalized(diagnosticProfile) ?? .off }
    var overlayMode: DebugOverlayMode { DebugOverlayMode.normalized(debugOverlayMode) ?? .off }

    var palette: ThemePalette { (ShellTheme(rawValue: theme) ?? .classic).palette }

    var language: ShellLanguage {
        ShellLanguage(rawValue: languageMode) ?? .system
    }

    var engineOptions: [(key: String, value: String)] {
        [("plugin_load_mode", pluginLoadMode), ("mock_enabled", mockEnabled ? "1" : "0"),
         ("error_dialog_logs", errorDialogLogs ? "1" : "0"),
         ("fps_limit", fpsLimitEnabled ? String(targetFPS) : "0")]
    }

    /// Effective ABI value: `0` disables engine-side limiting and lets the
    /// host follow the display refresh.
    var fpsLimitOption: String { fpsLimitEnabled ? String(targetFPS) : "0" }

    /// The resolved enhancement chain: off → none, preset → the preset's steps,
    /// custom → the stored chain. Only verified algorithms are ever returned.
    var enhancementSteps: [FrameEnhancement] {
        switch FrameEnhancementKind(rawValue: frameEnhancementKind) ?? .off {
        case .off: return []
        case .preset: return EnhancementPreset.normalized(frameEnhancementPreset)?.steps ?? []
        case .custom: return FrameEnhancementChain.normalized(frameEnhancementChain) ?? []
        }
    }
}

extension HostSettings {
    enum CodingKeys: String, CodingKey {
        case version, languageMode, theme, renderer, canvasMode, outputResolution, upscaleAlgorithm, virtualControls, logs, translationModelPath,
             fpsLimitEnabled, targetFPS, diagnosticProfile, debugOverlayMode, virtualControlMode, virtualControlMenuEnabled,
             virtualControlKeyboardOpacity, frameEnhancementAmount, pluginLoadMode, mockEnabled, errorDialogLogs,
             frameEnhancementKind, frameEnhancementPreset, frameEnhancementChain
    }
    /// v8 and earlier stored a single algorithm under this key.
    private enum LegacyCodingKeys: String, CodingKey {
        case frameEnhancement
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        languageMode = try values.decode(String.self, forKey: .languageMode)
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "classic"
        renderer = try values.decode(String.self, forKey: .renderer)
        canvasMode = try values.decodeIfPresent(String.self, forKey: .canvasMode) ?? "game"
        outputResolution = try values.decodeIfPresent(String.self, forKey: .outputResolution) ?? (version < 3 ? "original" : "1080p")
        upscaleAlgorithm = try values.decodeIfPresent(String.self, forKey: .upscaleAlgorithm) ?? (version < 4 ? "linear" : "bicubic")
        fpsLimitEnabled = try values.decodeIfPresent(Bool.self, forKey: .fpsLimitEnabled) ?? false
        targetFPS = try values.decodeIfPresent(Int.self, forKey: .targetFPS) ?? FrameScheduler.defaultTargetFPS
        diagnosticProfile = try values.decodeIfPresent(String.self, forKey: .diagnosticProfile) ?? HostSettings.defaultDiagnosticProfile
        debugOverlayMode = try values.decodeIfPresent(String.self, forKey: .debugOverlayMode) ?? "off"
        virtualControlMode = try values.decodeIfPresent(String.self, forKey: .virtualControlMode) ?? "mouse"
        virtualControlMenuEnabled = try values.decodeIfPresent(Bool.self, forKey: .virtualControlMenuEnabled) ?? true
        let storedOpacity = try values.decodeIfPresent(Double.self, forKey: .virtualControlKeyboardOpacity) ?? 1.0
        virtualControlKeyboardOpacity = VirtualControlOpacity.normalized(storedOpacity)
        let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyEnhancement = try legacyValues.decodeIfPresent(String.self, forKey: .frameEnhancement) ?? "off"
        if let kind = try values.decodeIfPresent(String.self, forKey: .frameEnhancementKind) {
            frameEnhancementKind = kind
        } else {
            frameEnhancementKind = legacyEnhancement == "off" ? "off" : FrameEnhancementKind.custom.rawValue
        }
        frameEnhancementPreset = try values.decodeIfPresent(String.self, forKey: .frameEnhancementPreset)
            ?? EnhancementPreset.defaultPreset.id
        if let chain = try values.decodeIfPresent([String].self, forKey: .frameEnhancementChain) {
            frameEnhancementChain = chain
        } else if legacyEnhancement != "off" {
            frameEnhancementChain = [legacyEnhancement]
        } else {
            frameEnhancementChain = EnhancementPreset.defaultPreset.steps.map(\.rawValue)
        }
        let storedEnhancement = try values.decodeIfPresent(Double.self, forKey: .frameEnhancementAmount) ?? 0.5
        frameEnhancementAmount = HostSettings.normalizedEnhancementAmount(storedEnhancement)
        virtualControls = try values.decode(Bool.self, forKey: .virtualControls)
        logs = try values.decode(Bool.self, forKey: .logs)
        translationModelPath = try values.decode(String.self, forKey: .translationModelPath)
        pluginLoadMode = try values.decode(String.self, forKey: .pluginLoadMode)
        mockEnabled = try values.decode(Bool.self, forKey: .mockEnabled)
        errorDialogLogs = try values.decode(Bool.self, forKey: .errorDialogLogs)
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
        if ["language", "renderer", "virtualControls", "logs", "translationModel"].contains(where: {
            defaults.object(forKey: legacyPrefix + $0) != nil
        }) { settings.outputResolution = "original"; settings.upscaleAlgorithm = "linear" }
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
