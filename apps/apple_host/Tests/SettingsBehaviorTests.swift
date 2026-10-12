import AppKit

@main
struct SettingsBehaviorTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-behavior-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("AETHER_HOST_LIBRARY_ROOT", root.path, 1)
        try RenderGeometryTests.run(root: root)
        try RendererBehaviorTests.run(root: root)
        FrameSchedulerTests.run()
        try PlayStatsTests.run(root: root)
        try DiagnosticTests.run(root: root)
        TransientToolsTests.run()
        VirtualControlsTests.run()
        try GameRuntimeTests.run(root: root)
        try FrameEnhancementTests.run(root: root)
        try LegalAcceptanceTests.run(root: root)
        try BuiltinDemoTests.run(root: root)
        try await CoverSearchTests.run(root: root)
        SceneTestTests.run()
        let model = ShellModel()
        try checkCollections(model, root: root)
        try checkPlayTimeAccumulation(model, root: root)
        model.openSettings()
        model.settingsDraft?.value.theme = "warm_dark"
        precondition(model.settings.theme == "classic" && model.settingsDirty)
        model.showLibrary()
        model.resolveSettingsNavigation(save: false)
        precondition(model.settings.theme == "classic")
        model.openSettings()
        model.settingsDraft?.value.theme = "warm_dark"
        precondition(model.saveSettings())
        precondition(model.settings.theme == "warm_dark" && model.settings.palette.dark)
        let themeRelaunch = ShellModel()
        precondition(themeRelaunch.settings.theme == "warm_dark")
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
        precondition(model.engine.appliedSettingOptions == ["plugin_load_mode": "aether_all", "mock_enabled": "1",
                                                            "error_dialog_logs": "0", "fps_limit": "0"])
        model.engine.shutdown()
        // FPS limit is a draft value that must survive save/relaunch and reach
        // the engine option as the target value, not as a host-side constant.
        model.openSettings()
        model.settingsDraft?.value.fpsLimitEnabled = true
        model.settingsDraft?.value.targetFPS = 120
        precondition(model.settings.fpsLimitEnabled == false && model.settingsDirty)
        precondition(model.saveSettings())
        let pacedRelaunch = ShellModel()
        precondition(pacedRelaunch.settings.fpsLimitEnabled && pacedRelaunch.settings.targetFPS == 120)
        precondition(pacedRelaunch.settings.fpsLimitOption == "120")
        model.engine.hostSettings = model.settings
        precondition(model.engine.initializeEngine(renderer: "software"))
        precondition(model.engine.appliedSettingOptions["fps_limit"] == "120")
        model.engine.shutdown()
        model.settingsDraft?.value.fpsLimitEnabled = false
        precondition(model.saveSettings())
        model.engine.hostSettings = model.settings
        precondition(model.engine.initializeEngine(renderer: "software"))
        precondition(model.engine.appliedSettingOptions["fps_limit"] == "0")
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
        precondition(model.settings.theme == "warm_dark")
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

    /// Runs a real library game and checks the play-time bookkeeping: only a
    /// successful session accumulates, return/restart commit exactly once and
    /// a failed startup contributes nothing.
    @MainActor static func checkPlayTimeAccumulation(_ model: ShellModel, root: URL) throws {
        let demo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("demos/aetherkiri-kag3/data")
        let imported = try model.repository.importDirectory(demo, existing: model.games, external: true).imported
        model.refreshLibrary()
        precondition(imported.playDurationSeconds == 0)
        setenv("AETHER_HOST_PACE", "timer", 1)
        defer { unsetenv("AETHER_HOST_PACE") }

        func storedSeconds() throws -> Int {
            try model.repository.load().first { $0.id == imported.id }?.playDurationSeconds ?? 0
        }
        func waitFor(_ marker: String, timeout: TimeInterval = 8) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !model.engine.logText.contains(marker), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return model.engine.logText.contains(marker)
        }
        func runLoop(for seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        model.selection = imported.id
        precondition(model.canPlay)
        model.play()
        precondition(model.activeGame?.id == imported.id)
        precondition(model.engine.consumePlaySeconds() == 0, "startup in flight must not count yet")
        precondition(waitFor("startup state: SUCCEEDED"), "test needs a real running session")
        runLoop(for: 1.2)
        model.returnToLibrary()
        precondition(model.activeGame == nil)
        let firstTotal = try storedSeconds()
        precondition(firstTotal >= 1, "a running session must accumulate play time")
        precondition(model.engine.consumePlaySeconds() == 0, "return must consume the session exactly once")

        // Returning again without a session must not add anything.
        model.returnToLibrary()
        let afterSecondReturn = try storedSeconds()
        precondition(afterSecondReturn == firstTotal)

        // Restart commits the finished session before the new one begins.
        model.selection = imported.id
        model.play()
        precondition(waitFor("startup state: SUCCEEDED"))
        runLoop(for: 1.2)
        model.restartActiveGame()
        let afterRestart = try storedSeconds()
        precondition(afterRestart >= firstTotal + 1, "restart must commit the previous session: \(afterRestart)")
        precondition(model.engine.consumePlaySeconds() <= 1, "restart must not leave pending time")
        model.returnToLibrary()

        // A rejected launch never opens a session, so it cannot accumulate time.
        precondition(!model.engine.openAndRun(gamePath: ""))
        precondition(model.engine.consumePlaySeconds() == 0, "a rejected launch must not accumulate time")
        model.engine.shutdown()
        print("PASS: running sessions accumulate capped play time; in-flight/rejected launches and repeated returns add nothing")
    }

    @MainActor static func checkCollections(_ model: ShellModel, root: URL) throws {
        precondition(model.visibleGames.isEmpty && model.gameDetailID == nil)
        let now = Date()
        var games = (0..<30).map { number -> LibraryGame in
            let id = UUID()
            return LibraryGame(id: id, title: "Game \(number)", directory: id.uuidString,
                               sourcePath: "/fixtures/Game \(number)", importedAt: now, lastPlayedAt: nil)
        }
        games[0].title = "Ｃafé 夏雪 日本語 한국어"
        games[0].lastPlayedAt = now
        games[0].coverSuppressed = true
        games[1].lastPlayedAt = now.addingTimeInterval(-1)
        try model.repository.save(games)
        model.refreshLibrary()
        precondition(model.visibleGames.count == 30 && model.visibleGames.first?.id == games[0].id)
        precondition(LibraryQuery.matches(["Ｃafé", "/fixtures/夏雪"], query: "CAFE 夏雪"))
        model.gameQuery = "cafe 夏雪"
        precondition(model.visibleGames.map(\.id) == [games[0].id])
        model.gameScrollAnchor = games[0].id
        model.openGameDetails(games[0])
        precondition(model.gameDetailID == games[0].id && model.selection == games[0].id)
        model.showGameCollection()
        precondition(model.gameDetailID == nil && model.gameQuery == "cafe 夏雪" && model.gameScrollAnchor == games[0].id)
        model.refreshLibrary()
        precondition(model.gameQuery == "cafe 夏雪" && model.games.first?.coverSuppressed == true)
        model.gameQuery = "no match"
        precondition(model.visibleGames.isEmpty && model.gameScrollAnchor == nil && model.games.count == 30)
        model.gameQuery = ""
        model.openGameDetails(games[0])
        _ = try model.repository.remove(games[0].id, existing: games)
        model.refreshLibrary()
        precondition(model.gameDetailID == nil && model.visibleGames.count == 29)

        let movie = root.appendingPathComponent("fixture.mp4")
        try Data("fixture".utf8).write(to: movie)
        let video = LibraryVideo(id: UUID(), path: movie.path, addedAt: now)
        try JSONEncoder().encode([video]).write(to: root.appendingPathComponent("video-library.json"))
        let progress = MediaProgressStore(url: root.appendingPathComponent("media-progress.json"))
        // Old entries have no total duration and must remain readable.
        let legacy: [String: Any] = [movie.path: ["seconds": 9.0, "updated": now.timeIntervalSinceReferenceDate]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: progress.url)
        let oldEntry = try progress.entries()[movie.path]
        precondition(oldEntry?.seconds == 9 && oldEntry?.duration == nil)
        try progress.save(12, for: movie, duration: 60)
        let subtitlesURL = root.appendingPathComponent("media-subtitles.json")
        try JSONEncoder().encode([movie.path: "fixture.srt", "other": "keep.srt"]).write(to: subtitlesURL)
        model.showVideos()
        precondition(model.visibleVideos.count == 1 && model.storedVideoProgress(for: video) == 12)
        model.videoQuery = "FIXTURE"
        precondition(model.visibleVideos.count == 1)
        model.videoQuery = "missing"
        precondition(model.visibleVideos.isEmpty && model.videos.count == 1)
        model.videoQuery = ""
        // A corrupt subtitle store blocks removal instead of silently losing preferences.
        let validSubtitles = try Data(contentsOf: subtitlesURL)
        try Data("broken".utf8).write(to: subtitlesURL)
        model.removeVideo(video)
        precondition(model.videos.count == 1)
        try validSubtitles.write(to: subtitlesURL)
        model.removeVideo(video)
        precondition(model.videos.isEmpty && FileManager.default.fileExists(atPath: movie.path))
        let remainingProgress = try progress.entries()
        precondition(remainingProgress[movie.path] == nil)
        let remainingSubtitles = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: subtitlesURL))
        precondition(remainingSubtitles[movie.path] == nil && remainingSubtitles["other"] == "keep.srt")
        let storedVideos = try JSONDecoder().decode([LibraryVideo].self, from: Data(contentsOf: root.appendingPathComponent("video-library.json")))
        precondition(storedVideos.isEmpty)
        model.error = nil
        print("PASS: 0/1/30 entries, normalized search, recent sorting, detail return, refresh, legacy progress, confirmed removal cleanup and failure retention")
    }
}
