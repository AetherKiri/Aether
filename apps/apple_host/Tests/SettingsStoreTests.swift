import Foundation

@main
struct SettingsStoreTests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "aether-settings-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let fresh = try store.load(defaults: defaults, legacyPrefix: "fresh.")
        precondition(fresh.renderer == "metal" && fresh.languageMode == "system" && fresh.mockEnabled && fresh.theme == "classic" && fresh.upscaleAlgorithm == "bicubic")
        precondition(!fresh.fpsLimitEnabled && fresh.targetFPS == 80 && fresh.fpsLimitOption == "0")
        precondition(fresh.version == 7)
        precondition(fresh.diagnosticProfile == HostSettings.defaultDiagnosticProfile && fresh.debugOverlayMode == "off")
        precondition(fresh.virtualControlMode == "mouse" && fresh.virtualControlMenuEnabled && fresh.virtualControlKeyboardOpacity == 1.0)
        let legacy = SettingsStore(url: root.appendingPathComponent("legacy/settings.json"))
        defaults.set("software", forKey: "shell.renderer")
        defaults.set("japanese", forKey: "shell.language")
        defaults.set(true, forKey: "shell.virtualControls")
        defaults.set("/tmp/model.gguf", forKey: "shell.translationModel")
        let migrated = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(migrated.renderer == "software" && migrated.languageMode == "japanese")
        precondition(migrated.virtualControls && migrated.translationModelPath == "/tmp/model.gguf")
        defaults.set("metal", forKey: "shell.renderer")
        let loaded = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(loaded == migrated, "migration must not run twice")
        // A genuine v1 file lacks theme and must retain every existing option.
        var v1 = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy.url)) as! [String: Any]
        v1["version"] = 1
        v1.removeValue(forKey: "theme")
        v1.removeValue(forKey: "canvasMode")
        v1.removeValue(forKey: "outputResolution")
        let oldData = try JSONSerialization.data(withJSONObject: v1)
        try oldData.write(to: legacy.url)
        let upgraded = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(upgraded == loaded && upgraded.version == 7 && upgraded.theme == "classic")
        precondition(!upgraded.fpsLimitEnabled && upgraded.targetFPS == 80)
        check(try Data(contentsOf: legacy.url) == oldData) // Loading does not overwrite the migration source.
        var v2 = v1
        v2["version"] = 2
        v2.removeValue(forKey: "canvasMode")
        v2.removeValue(forKey: "outputResolution")
        try JSONSerialization.data(withJSONObject: v2).write(to: legacy.url)
        let oldGeometry = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(oldGeometry.outputResolution == "original" && oldGeometry.canvasMode == "game")
        precondition(oldGeometry.upscaleAlgorithm == "linear")
        var v3 = v2
        v3["version"] = 3
        v3["canvasMode"] = "display"
        v3["outputResolution"] = "1080p"
        v3.removeValue(forKey: "upscaleAlgorithm")
        try JSONSerialization.data(withJSONObject: v3).write(to: legacy.url)
        let oldSampling = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(oldSampling.canvasMode == "display" && oldSampling.outputResolution == "1080p" && oldSampling.upscaleAlgorithm == "linear")
        // A v4 file has no FPS fields and must migrate to off with target 80.
        var v4 = v3
        v4["version"] = 4
        v4["upscaleAlgorithm"] = "bicubic"
        v4.removeValue(forKey: "fpsLimitEnabled")
        v4.removeValue(forKey: "targetFPS")
        try JSONSerialization.data(withJSONObject: v4).write(to: legacy.url)
        let oldFPS = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(oldFPS.upscaleAlgorithm == "bicubic" && !oldFPS.fpsLimitEnabled && oldFPS.targetFPS == 80)
        precondition(oldFPS.fpsLimitOption == "0")
        // A v6 file has no virtual-control fields: mouse pad, entry shown, opaque.
        var v6 = v4
        v6["version"] = 6
        v6.removeValue(forKey: "virtualControlMode")
        v6.removeValue(forKey: "virtualControlMenuEnabled")
        v6.removeValue(forKey: "virtualControlKeyboardOpacity")
        try JSONSerialization.data(withJSONObject: v6).write(to: legacy.url)
        let oldVirtual = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(oldVirtual.version == 7)
        precondition(oldVirtual.virtualControlMode == "mouse" && oldVirtual.virtualControlMenuEnabled)
        precondition(oldVirtual.virtualControlKeyboardOpacity == 1.0)
        // Stored opacity is snapped to 0.05 like Godot; bad values are rejected.
        for (input, expected) in [(0.62, 0.6), (0.63, 0.65), (0.85, 0.85), (1.0, 1.0), (0.2, 0.2)] {
            var value = loaded
            value.virtualControlKeyboardOpacity = input
            try legacy.save(value)
            let reloaded = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
            precondition(abs(reloaded.virtualControlKeyboardOpacity - expected) < 0.0001,
                         "opacity \(input) -> \(reloaded.virtualControlKeyboardOpacity), expected \(expected)")
        }
        for mode in VirtualControlMode.allCases {
            var value = loaded
            value.virtualControlMode = mode.rawValue
            value.virtualControlKeyboardOpacity = 0.2
            try legacy.save(value)
            let reloaded = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
            precondition(reloaded.virtualControlMode == mode.rawValue && reloaded.virtualControlKeyboardOpacity == 0.2)
        }
        var invalidVirtual = loaded
        invalidVirtual.virtualControlMode = "pad"
        do { try legacy.save(invalidVirtual); preconditionFailure("unknown virtual control mode accepted") } catch {}
        invalidVirtual = loaded
        invalidVirtual.virtualControlKeyboardOpacity = 0.1
        do { try legacy.save(invalidVirtual); preconditionFailure("opacity below the minimum accepted") } catch {}
        invalidVirtual = loaded
        invalidVirtual.virtualControlKeyboardOpacity = 1.2
        do { try legacy.save(invalidVirtual); preconditionFailure("opacity above the maximum accepted") } catch {}
        var unknownVirtual = loaded
        unknownVirtual.virtualControlMode = "pad"
        unknownVirtual.virtualControlKeyboardOpacity = 0.0
        try JSONEncoder().encode(unknownVirtual).write(to: store.url)
        let normalizedVirtual = try store.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(normalizedVirtual.virtualControlMode == "mouse")
        precondition(normalizedVirtual.virtualControlKeyboardOpacity == 0.2)
        precondition(fresh.outputResolution == "1080p")
        for target in FrameScheduler.supportedTargets {
            var value = loaded
            value.fpsLimitEnabled = true
            value.targetFPS = target
            try legacy.save(value)
            let reloaded = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
            precondition(reloaded == value && reloaded.fpsLimitOption == String(target))
        }
        for option in loaded.engineOptions {
            precondition(option.key != "fps_limit" || option.value == "0")
        }
        for mode in CanvasMode.allCases {
            for resolution in OutputResolution.allCases {
                var value = loaded
                value.canvasMode = mode.rawValue
                value.outputResolution = resolution.rawValue
                value.upscaleAlgorithm = resolution == .original ? "linear" : "bicubic"
                try legacy.save(value)
                check(try legacy.load(defaults: defaults, legacyPrefix: "shell.") == value)
            }
        }
        for theme in ShellTheme.allCases {
            var value = loaded
            value.theme = theme.rawValue
            try legacy.save(value)
            check(try legacy.load(defaults: defaults, legacyPrefix: "shell.") == value)
            let palette = theme.palette
            for background in [palette.background, palette.raised, palette.surface] {
                precondition(palette.primary.contrast(with: background) >= 4.5)
                precondition(palette.secondary.contrast(with: background) >= 4.5)
                precondition(palette.accentText.contrast(with: background) >= 4.5)
            }
            precondition(ThemePalette.Ink(hex: 0xffffff).contrast(with: palette.controlAccent) >= 5)
            precondition(palette.increasedContrast().secondary == palette.primary)
        }
        try legacy.save(loaded)
        var draft = SettingsDraft(loaded)
        draft.value.renderer = "metal"
        draft.value.translationModelPath = ""
        precondition(draft.isDirty)
        check(try legacy.load(defaults: defaults, legacyPrefix: "shell.") == loaded)
        draft.discard()
        precondition(!draft.isDirty && draft.value == loaded)
        draft.value.mockEnabled = false
        try legacy.save(draft.value)
        draft.accept(draft.value)
        precondition(!draft.isDirty)
        check(try legacy.load(defaults: defaults, legacyPrefix: "shell.") == draft.value)
        let originalData = try Data(contentsOf: legacy.url)
        var invalid = draft.value
        invalid.renderer = "unknown"
        do { try legacy.save(invalid); preconditionFailure("invalid value saved") } catch {}
        check(try Data(contentsOf: legacy.url) == originalData)
        var unknown = loaded
        unknown.renderer = "unknown"
        unknown.languageMode = "unknown"
        unknown.pluginLoadMode = "unknown"
        unknown.theme = "unknown"
        try JSONEncoder().encode(unknown).write(to: store.url)
        let normalized = try store.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(normalized.renderer == "metal" && normalized.languageMode == "system" && normalized.pluginLoadMode == "krkrsdl3" && normalized.theme == "classic")
        check(try JSONDecoder().decode(HostSettings.self, from: Data(contentsOf: store.url)).renderer == "unknown")
        invalid = loaded
        invalid.theme = "unknown"
        do { try legacy.save(invalid); preconditionFailure("invalid theme saved") } catch {}
        invalid = loaded
        invalid.outputResolution = "8k"
        do { try legacy.save(invalid); preconditionFailure("invalid resolution saved") } catch {}
        invalid.outputResolution = "original"
        invalid.upscaleAlgorithm = "smooth"
        try legacy.save(invalid)
        let normalizedSampling = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(normalizedSampling.upscaleAlgorithm == "linear")
        invalid.canvasMode = "unknown"
        do { try legacy.save(invalid); preconditionFailure("invalid canvas saved") } catch {}
        invalid.canvasMode = "game"
        invalid.upscaleAlgorithm = "unknown"
        do { try legacy.save(invalid); preconditionFailure("invalid sampling saved") } catch {}
        invalid.upscaleAlgorithm = "bicubic"
        for invalidTarget in [0, 30, 59, 75, 100, 143, 165] {
            var value = loaded
            value.fpsLimitEnabled = true
            value.targetFPS = invalidTarget
            do { try legacy.save(value); preconditionFailure("invalid target \(invalidTarget) saved") } catch {}
        }
        var invalidMode = loaded
        invalidMode.fpsLimitEnabled = true
        invalidMode.targetFPS = 90
        try legacy.save(invalidMode)
        let limitedMode = try legacy.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(limitedMode.fpsLimitOption == "90" && limitedMode.fpsLimitEnabled && limitedMode.targetFPS == 90)
        try legacy.save(loaded)
        invalid.version = 99
        do { _ = try invalid.validated(); preconditionFailure("future version accepted") } catch {}
        let future = try JSONEncoder().encode(invalid)
        try future.write(to: store.url)
        do { _ = try store.load(defaults: defaults, legacyPrefix: "shell."); preconditionFailure("future file loaded") } catch {}
        check(try Data(contentsOf: store.url) == future)
        // A real filesystem failure must not allow the caller to accept a draft.
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        let broken = SettingsStore(url: blocker.appendingPathComponent("settings.json"))
        draft.value.logs.toggle()
        do { try broken.save(draft.value); preconditionFailure("failed write succeeded") } catch {}
        precondition(draft.isDirty)
        try Data("not json".utf8).write(to: store.url)
        do { _ = try store.load(defaults: defaults, legacyPrefix: "shell."); preconditionFailure("corrupt file replaced") } catch {}
        check(try Data(contentsOf: store.url) == Data("not json".utf8))
        precondition(draft.value.engineOptions.map(\.key) == ["plugin_load_mode", "mock_enabled", "error_dialog_logs", "fps_limit"])
        print("PASS: schema v1-v5/theme migration, FPS target persistence and validation, four-theme contrast, draft isolation, discard/save, filesystem failure and corrupt-file preservation")
    }
}
