import AppKit

@main
struct SettingsBehaviorTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-behavior-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("AETHER_HOST_LIBRARY_ROOT", root.path, 1)
        let model = ShellModel()
        model.openSettings()
        precondition(model.route == .settings && model.settingsDraft != nil)
        model.settingsDraft?.value.mockEnabled = false
        precondition(model.settings.mockEnabled && model.settingsDirty)
        model.showDashboard()
        precondition(model.route == .settings && model.confirmDiscardSettings)
        model.cancelSettingsNavigation()
        precondition(model.route == .settings && model.settingsDirty)
        model.showDashboard()
        model.resolveSettingsNavigation(save: false)
        precondition(model.route == .dashboard && model.settings.mockEnabled)
        model.openSettings()
        model.settingsDraft?.value.pluginLoadMode = "aether_all"
        model.settingsDraft?.value.languageMode = "english"
        model.showVideos()
        model.resolveSettingsNavigation(save: true)
        precondition(model.route == .videos && !model.settingsDirty)
        precondition(model.settings.pluginLoadMode == "aether_all" && model.language == .english)
        let relaunched = ShellModel()
        precondition(relaunched.settings == model.settings)
        model.engine.hostSettings = model.settings
        precondition(model.engine.initializeEngine(renderer: "software"))
        precondition(model.engine.appliedSettingOptions == ["plugin_load_mode": "aether_all", "mock_enabled": "1", "error_dialog_logs": "0"])
        model.engine.shutdown()
        model.openSettings()
        model.settingsDraft?.value.renderer = "invalid"
        var left = false
        var cancelled = false
        model.requestLeaveSettings(action: { left = true }, cancel: { cancelled = true })
        model.resolveSettingsNavigation(save: true)
        precondition(!left && model.settingsDirty && model.settings.renderer == "metal")
        model.cancelSettingsNavigation()
        precondition(cancelled && !left)
        model.settingsDraft?.value.renderer = "software"
        // Replace the destination with a directory to exercise an actual write failure.
        let settingsURL = root.appendingPathComponent("settings.json")
        try FileManager.default.removeItem(at: settingsURL)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)
        precondition(!model.saveSettings())
        precondition(model.settings.renderer == "metal" && model.settingsDirty)
        var closed = false
        model.requestLeaveSettings(action: { closed = true })
        model.resolveSettingsNavigation(save: false)
        precondition(closed && !model.settingsDirty)
        let corrupted = ShellModel()
        corrupted.openSettings()
        corrupted.settingsDraft?.value.logs = true
        precondition(!corrupted.canSaveSettings && !corrupted.saveSettings())
        precondition(FileManager.default.fileExists(atPath: settingsURL.path))
        if let path = ProcessInfo.processInfo.environment["AETHER_SETTINGS_APP_BUNDLE"], let bundle = Bundle(path: path) {
            for language in ShellLanguage.allCases {
                precondition(SettingsDocument.privacy.contents(language: language, bundle: bundle)?.isEmpty == false)
            }
            for document in [SettingsDocument.license, .additionalLicense, .thirdParty] {
                precondition(document.contents(language: .english, bundle: bundle)?.isEmpty == false)
            }
        }
        print("PASS: real ShellModel navigation, cancel/discard/save, relaunch, pending close, validation and failed-write isolation")
    }
}
