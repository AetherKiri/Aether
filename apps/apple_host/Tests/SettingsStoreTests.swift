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
        precondition(fresh.renderer == "metal" && fresh.languageMode == "system" && fresh.mockEnabled)
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
        try JSONEncoder().encode(unknown).write(to: store.url)
        let normalized = try store.load(defaults: defaults, legacyPrefix: "shell.")
        precondition(normalized.renderer == "metal" && normalized.languageMode == "system" && normalized.pluginLoadMode == "krkrsdl3")
        check(try JSONDecoder().decode(HostSettings.self, from: Data(contentsOf: store.url)).renderer == "unknown")
        invalid.version = 99
        do { _ = try invalid.validated(); preconditionFailure("future version accepted") } catch {}
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
        precondition(draft.value.engineOptions.map(\.key) == ["plugin_load_mode", "mock_enabled", "error_dialog_logs"])
        print("PASS: migration, draft isolation, discard/save, validation, filesystem failure and corrupt-file preservation")
    }
}
