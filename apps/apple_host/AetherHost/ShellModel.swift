import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShellRoute: String {
    case library
    case videos
    case dashboard
    case settings
    var textKey: String {
        switch self {
        case .library: return "library"
        case .videos: return "videoLibrary"
        case .dashboard: return "dashboard"
        case .settings: return "settings"
        }
    }
}

struct LibraryVideo: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String { url.lastPathComponent }
}

@MainActor
final class ShellModel: ObservableObject {
    let engine = EngineController()
    let repository: GameLibrary
    lazy var media = MediaController(root: repository.root, diagnostics: engine.diagnostics, log: { [weak self] in self?.engine.log($0) })
    @Published var activeVideo: URL?
    @Published var games: [LibraryGame] = []
    @Published var videos: [LibraryVideo] = []
    @Published var gameQuery = "" { didSet { if oldValue != gameQuery { gameScrollAnchor = nil } } }
    @Published var videoQuery = "" { didSet { if oldValue != videoQuery { videoScrollAnchor = nil } } }
    @Published var gameDetailID: UUID?
    @Published var gameListLayout = false
    @Published var videoListLayout = false
    var gameScrollAnchor: UUID?
    var videoScrollAnchor: UUID?
    @Published var pendingVideoRemoval: LibraryVideo?
    @Published private(set) var videoProgressEntries: [String: MediaProgressStore.Entry] = [:]
    @Published var selection: UUID?
    @Published var selectedVideoID: UUID?
    @Published var activeGame: LibraryGame?
    @Published private(set) var route: ShellRoute = .library
    @Published var isImporting = false
    @Published var error: String?
    @Published var renameGame: LibraryGame?
    @Published var renameTitle = ""
    @Published var renameError: String?
    @Published var removeGame: LibraryGame?
    @Published var confirmReturn = false { didSet { syncGameInput() } }
    @Published var confirmRestart = false { didSet { syncGameInput() } }
    @Published var showSettings = false { didSet {
        if showSettings && settingsDraft == nil { settingsDraft = SettingsDraft(settings) }
        syncGameInput()
    } }
    @Published var showGameTextEntry = false { didSet { syncGameInput() } }
    @Published var showVirtualControls: Bool { didSet {
        if !showVirtualControls { engine.releaseVirtualKeys() }
    } }
    @Published var language: ShellLanguage
    @Published var renderer: String
    @Published var showLogs: Bool
    @Published var translationModelPath: String
    @Published private(set) var settings: HostSettings
    @Published var settingsDraft: SettingsDraft?
    @Published var confirmDiscardSettings = false
    private var pendingSettingsAction: (() -> Void)?
    private var pendingSettingsCancel: (() -> Void)?
    private let settingsStore: SettingsStore
    @Published private(set) var settingsAvailable = true
    @Published private(set) var isFullscreen = false
    private let preferencePrefix: String
    private var libraryAvailable = true
    private var fullscreenBeforeGame: Bool?
    private var videoIndexURL: URL { repository.root.appendingPathComponent("video-library.json") }
    private var mediaProgress: MediaProgressStore { MediaProgressStore(url: repository.root.appendingPathComponent("media-progress.json")) }

    init() {
        let defaults = UserDefaults.standard
        preferencePrefix = ProcessInfo.processInfo.environment["AETHER_HOST_LIBRARY_ROOT"].map { $0 + "::shell." } ?? "shell."
        let root = ProcessInfo.processInfo.environment["AETHER_HOST_LIBRARY_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether", isDirectory: true)
        repository = GameLibrary(root: root)
        settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let initial: HostSettings
        var settingsFailure: Error?
        do { initial = try settingsStore.load(defaults: defaults, legacyPrefix: preferencePrefix) }
        catch { initial = HostSettings(); settingsFailure = error }
        settings = initial
        language = initial.language
        renderer = initial.renderer
        showLogs = initial.logs
        showVirtualControls = initial.virtualControls
        translationModelPath = initial.translationModelPath
        if let settingsFailure {
            settingsAvailable = false
            self.error = text("settingsLoadFailed") + "\n" + settingsFailure.localizedDescription
        }
        do {
            games = try repository.backfillDefaultCovers(try repository.load())
            selection = games.first?.id
            videos = loadVideos()
            selectedVideoID = videos.first?.id
            reloadVideoProgress()
        }
        catch { self.error = friendlyError(error); libraryAvailable = false }
    }

    private func friendlyError(_ error: Error) -> String {
        if let failure = error as? GameLibrary.Failure {
            switch failure {
            case .invalidTitle: return text("invalidTitle")
            case .unsupported: return text("unsupported")
            case .unsafeSource: return text("unsafeSource")
            case .symbolicLink: return text("symbolicLink")
            case .invalidManifest: return text("invalidIndex")
            }
        }
        if let failure = error as? GameArchive.Failure {
            switch failure {
            case .invalid: return text("archiveInvalid")
            case .unsafe: return text("archiveUnsafe")
            case .tooLarge: return text("archiveLarge")
            case .ambiguous: return text("archiveAmbiguous")
            }
        }
        if error is DecodingError { return text("invalidIndex") }
        return error.localizedDescription
    }

    var settingsDirty: Bool { settingsDraft?.isDirty ?? false }
    var canSaveSettings: Bool { settingsAvailable && settingsDirty }

    @discardableResult
    func saveSettings() -> Bool {
        guard settingsAvailable, let draft = settingsDraft else { return false }
        if draft.value.translationModelPath != settings.translationModelPath,
           !draft.value.translationModelPath.isEmpty,
           let failure = TranslationSettings.validate(path: draft.value.translationModelPath) {
            error = translationFailureText(failure)
            return false
        }
        do {
            try settingsStore.save(draft.value)
            settings = draft.value
            language = settings.language
            renderer = settings.renderer
            showVirtualControls = settings.virtualControls
            showLogs = settings.logs
            translationModelPath = settings.translationModelPath
            settingsDraft = SettingsDraft(settings)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func requestLeaveSettings(action: @escaping () -> Void, cancel: (() -> Void)? = nil) {
        if confirmDiscardSettings { cancel?(); return }
        if settingsDirty {
            pendingSettingsAction = action
            pendingSettingsCancel = cancel
            confirmDiscardSettings = true
        } else { action() }
    }

    func resolveSettingsNavigation(save: Bool) {
        if save && !saveSettings() { cancelSettingsNavigation(); return }
        let action = pendingSettingsAction
        settingsDraft = SettingsDraft(settings)
        pendingSettingsAction = nil
        pendingSettingsCancel = nil
        confirmDiscardSettings = false
        action?()
    }

    func cancelSettingsNavigation() {
        pendingSettingsCancel?()
        pendingSettingsAction = nil
        pendingSettingsCancel = nil
        confirmDiscardSettings = false
    }

    func requestRoute(_ destination: ShellRoute) {
        guard canNavigateShell, destination != route else { return }
        requestLeaveSettings { [weak self] in
            guard let self else { return }
            self.settingsDraft = nil
            self.route = destination
            self.showSettings = destination == .settings
        }
    }

    func openSettings() {
        guard canOpenSettings else { return }
        requestRoute(.settings)
    }

    private func syncGameInput() {
        let suspended = showSettings || confirmReturn || confirmRestart || showGameTextEntry
        engine.platformDialogs.setPresentationAllowed(!suspended)
        engine.setInputSuspended(suspended)
    }

    func text(_ key: String) -> String { language.text(key) }
    var selectedGame: LibraryGame? { games.first { $0.id == selection } }
    var canImport: Bool { libraryAvailable && !isImporting && activeGame == nil && activeVideo == nil }
    var canPlay: Bool { !isImporting && activeGame == nil && activeVideo == nil && selectedGame != nil }
    var canRestartGame: Bool { activeGame != nil && activeVideo == nil && !engine.runtimeMovieActive }
    var canEditCover: Bool { canImport && selectedGame != nil }
    var canNavigateShell: Bool { activeGame == nil && activeVideo == nil && !isImporting }
    var canOpenSettings: Bool { activeGame == nil && activeVideo == nil && !isImporting }

    var visibleGames: [LibraryGame] { LibraryQuery.games(games, query: gameQuery) }
    var visibleVideos: [LibraryVideo] {
        videos.filter { LibraryQuery.matches([$0.displayTitle, $0.path], query: videoQuery) }
            .sorted {
                let left = videoProgressEntries[$0.path]?.updated ?? $0.addedAt
                let right = videoProgressEntries[$1.path]?.updated ?? $1.addedAt
                if left != right { return left > right }
                let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    func openGameDetails(_ game: LibraryGame) {
        guard canNavigateShell else { return }
        requestLeaveSettings { [weak self] in
            guard let self else { return }
            self.settingsDraft = nil
            self.showSettings = false
            self.route = .library
            self.selection = game.id
            self.gameDetailID = game.id
        }
    }

    func showGameCollection() { gameDetailID = nil }

    private func reloadVideoProgress() {
        do { videoProgressEntries = try mediaProgress.entries() }
        catch { self.error = error.localizedDescription }
    }

    func coverImage(for game: LibraryGame) -> NSImage? {
        guard let url = repository.coverURL(game), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    func chooseImport(external: Bool = false) {
        guard canImport else { return }
        isImporting = true
        let panel = NSOpenPanel()
        panel.title = text(external ? "linkGame" : "import")
        panel.message = text(external ? "linkHelp" : "archiveImportHelp")
        panel.prompt = text(external ? "linkGame" : "import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = !external
        if !external { panel.allowedContentTypes = [.folder, .zip] }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { isImporting = false; return }
        let repository = self.repository
        let existing = games
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if !external, source.pathExtension.lowercased() == "zip",
                       (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
                        return try repository.importArchive(source, existing: existing)
                    }
                    return try repository.importDirectory(source, existing: existing, external: external)
                }.value
                games = try repository.backfillDefaultCovers(result.games)
                selection = result.imported.id
                gameDetailID = nil
            } catch { self.error = friendlyError(error) }
            isImporting = false
        }
    }

    func refreshLibrary() {
        guard canNavigateShell else { return }
        do {
            let currentSelection = selection
            games = try repository.backfillDefaultCovers(try repository.load())
            selection = games.contains(where: { $0.id == currentSelection }) ? currentSelection : games.first?.id
            videos = loadVideos()
            reloadVideoProgress()
            if !games.contains(where: { $0.id == gameDetailID }) { gameDetailID = nil }
            selectedVideoID = videos.contains(where: { $0.id == selectedVideoID }) ? selectedVideoID : videos.first?.id
        } catch let failure { self.error = friendlyError(failure) }
    }

    func showLibrary() {
        guard canNavigateShell else { return }
        requestRoute(.library)
        showGameCollection()
        refreshLibrary()
    }

    func showVideos() {
        guard canNavigateShell else { return }
        requestRoute(.videos)
        videos = loadVideos()
        reloadVideoProgress()
        selectedVideoID = videos.first?.id
    }

    func showDashboard() {
        guard canNavigateShell else { return }
        requestRoute(.dashboard)
    }

    private func loadVideos() -> [LibraryVideo] {
        guard FileManager.default.fileExists(atPath: videoIndexURL.path) else { return [] }
        do { return try JSONDecoder().decode([LibraryVideo].self, from: Data(contentsOf: videoIndexURL)) }
        catch { self.error = text("invalidIndex"); return [] }
    }

    private func saveVideos() throws {
        try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(videos).write(to: videoIndexURL, options: .atomic)
    }

    private func rememberVideo(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !videos.contains(where: { $0.path == path }) else { return }
        videos.append(LibraryVideo(id: UUID(), path: path, addedAt: Date()))
        do { try saveVideos() } catch let failure { self.error = failure.localizedDescription }
    }

    func removeVideo(_ video: LibraryVideo) {
        guard activeGame == nil else { return }
        if activeVideo?.standardizedFileURL.path == video.url.standardizedFileURL.path { closeVideo() }
        let previous = videos
        do {
            try media.forgetSubtitleSelection(for: video.url)
            try mediaProgress.remove(for: video.url)
            videos = videos.filter { $0.id != video.id }
            do { try saveVideos() } catch { videos = previous; throw error }
            if selectedVideoID == video.id { selectedVideoID = nil }
            pendingVideoRemoval = nil
            reloadVideoProgress()
        } catch let failure { self.error = failure.localizedDescription }
    }

    func storedVideoProgress(for video: LibraryVideo) -> Double {
        videoProgressEntries[video.path]?.seconds ?? 0
    }

    func chooseCover() {
        guard canEditCover, let game = selectedGame else { return }
        let panel = NSOpenPanel()
        panel.title = text("dialogChooseCover")
        panel.message = text("dialogChooseCoverHelp")
        panel.prompt = text("setCover")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard NSImage(contentsOf: url) != nil else {
            error = text("messageCoverFileMissing")
            return
        }
        do {
            games = try repository.setCover(game.id, url: url, existing: games)
        } catch let failure { error = friendlyError(failure) }
    }

    func clearSelectedCover() {
        guard canEditCover, let game = selectedGame else { return }
        do { games = try repository.clearCover(game.id, existing: games) }
        catch let failure { error = friendlyError(failure) }
    }

    func beginRename(_ game: LibraryGame) {
        guard canImport else { return }
        renameError = nil
        renameTitle = game.displayTitle
        renameGame = game
    }

    func saveRename() {
        guard canImport, let game = renameGame else { return }
        do { games = try repository.rename(game.id, title: renameTitle, existing: games); renameGame = nil; renameError = nil }
        catch { renameError = friendlyError(error) }
    }

    func removeSelectedGame() {
        guard canImport, let game = removeGame else { return }
        do {
            games = try repository.remove(game.id, existing: games)
            if selection == game.id { selection = nil }
            if gameDetailID == game.id { gameDetailID = nil }
            removeGame = nil
        } catch { self.error = friendlyError(error) }
    }

    func play() {
        guard canPlay, let game = selectedGame else { return }
        requestLeaveSettings { [weak self] in
            guard let self else { return }
            self.settingsDraft = nil
            self.showSettings = false
            self.route = .library
            self.startGame(game, fullscreenBefore: self.windowIsFullscreen)
        }
    }

    private func startGame(_ game: LibraryGame, fullscreenBefore: Bool) {
        let path = repository.gameURL(game).path
        guard FileManager.default.fileExists(atPath: path) else {
            error = text("missing")
            fullscreenBeforeGame = nil
            return
        }
        fullscreenBeforeGame = fullscreenBefore
        engine.prepareDiagnostics(gamePath: path, title: game.displayTitle)
        // Applied by initializeEngine() before the game opens; the target
        // language follows the interface language, as in the Godot shell.
        engine.hostSettings = settings
        showVirtualControls = settings.virtualControls
        showLogs = settings.logs
        engine.translationSettings = translationSettings
        engine.translationTargetLanguage = TranslationSettings.targetLanguageCode(for: language)
        guard engine.initializeEngine(renderer: renderer), engine.openAndRun(gamePath: path) else {
            error = engine.failureMessage
            engine.shutdown()
            fullscreenBeforeGame = nil
            return
        }
        activeGame = game
        var updated = games
        if let index = updated.firstIndex(where: { $0.id == game.id }) {
            updated[index].lastPlayedAt = Date()
            do { try repository.save(updated); games = updated }
            catch { self.error = friendlyError(error) }
        }
    }

    func restartActiveGame() {
        guard canRestartGame, let game = activeGame else { return }
        let fullscreen = windowIsFullscreen
        showGameTextEntry = false
        confirmRestart = false
        engine.shutdown()
        activeGame = nil
        startGame(game, fullscreenBefore: fullscreen)
    }

    var canOpenVideo: Bool { !isImporting && activeGame == nil && activeVideo == nil }

    func chooseVideo() {
        guard canOpenVideo else { return }
        let panel = NSOpenPanel()
        panel.title = text("openVideo")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video] + ["mkv", "webm", "avi", "mpeg", "m4v"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVideo(url)
    }

    func openVideo(_ url: URL) {
        guard canOpenVideo else { return }
        requestLeaveSettings { [weak self] in
            guard let self else { return }
            self.settingsDraft = nil
            self.showSettings = false
            self.route = .videos
            if self.media.open(url) {
                self.activeVideo = url
                self.rememberVideo(url)
                if let subtitleError = self.media.subtitleError { self.error = subtitleError; self.media.subtitleError = nil }
            } else { self.error = self.media.failureMessage }
        }
    }

    func closeVideo() {
        media.close()
        activeVideo = nil
        reloadVideoProgress()
        route = .videos
    }

    func closeActiveSession() {
        if activeGame != nil { returnToLibrary() }
        if activeVideo != nil { closeVideo() }
    }

    var windowIsFullscreen: Bool {
        hostWindow?.styleMask.contains(.fullScreen) ?? false
    }

    func refreshFullscreenState() {
        isFullscreen = windowIsFullscreen
    }

    func toggleFullscreen() {
        hostWindow?.toggleFullScreen(nil)
    }

    func revealActiveGame() {
        guard let game = activeGame else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repository.gameURL(game)])
    }

    private var hostWindow: NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = text("exportDiagnostics")
        panel.nameFieldStringValue = "Aether-Diagnostics-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            engine.log("diagnostic export requested")
            try engine.diagnostics.export(to: destination, context: [
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": "arm64", "language": language.rawValue,
                "nextLaunchRenderer": renderer, "library": repository.root.path,
                "liveStatus": activeVideo == nil ? engine.status : media.playing ? "video playing" : "video paused", "liveTicks": String(engine.tickCount)
            ])
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { self.error = error.localizedDescription }
    }

    func openQQGroup() {
        let url = URL(string: "https://aetherkiri.github.io/qq/")!
        if !NSWorkspace.shared.open(url) { error = url.absoluteString }
    }

    // MARK: - Local translation model (mirrors the Godot shell's settings row)

    var translationSettings: TranslationSettings { TranslationSettings(modelPath: translationModelPath) }
    var capabilities: HostCapabilities { engine.capabilities }
    var translationAvailable: Bool {
        capabilities.translation.available || translationConfigurationPreview
    }
    var translationConfigurationPreview: Bool {
        #if DEBUG
        return !capabilities.translation.available && ProcessInfo.processInfo.environment["AETHER_HOST_DEBUG_TRANSLATION"] == "1"
        #else
        return false
        #endif
    }

    func chooseTranslationModel() {
        let panel = NSOpenPanel()
        panel.title = text("translationModelSelect")
        panel.message = text("translationModelHelp")
        panel.prompt = text("translationModelSelect")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: TranslationSettings.modelFileExtension) {
            panel.allowedContentTypes = [gguf]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectTranslationModel(path: url.path)
    }

    /// Validates and persists a model path. Returns the user-facing error text
    /// when the file cannot be used; the previous path is kept in that case.
    @discardableResult
    func selectTranslationModel(path: String) -> String? {
        if let failure = TranslationSettings.validate(path: path) {
            let message = translationFailureText(failure)
            error = message
            engine.log("translation model rejected")
            return message
        }
        guard settingsDraft != nil else { return nil }
        settingsDraft?.value.translationModelPath = path
        engine.log("translation model selected (\(TranslationSettings.displayName(for: path)))")
        return nil
    }

    func clearTranslationModel() {
        guard settingsDraft != nil else { return }
        settingsDraft?.value.translationModelPath = ""
        engine.log("translation model cleared")
    }

    private func translationFailureText(_ failure: TranslationSettings.Failure) -> String {
        switch failure {
        case .wrongExtension: return text("translationModelExtension")
        case .empty, .missingFile, .notReadable: return text("translationModelMissing")
        }
    }

    func returnToLibrary() {
        showGameTextEntry = false
        engine.shutdown()
        activeGame = nil
        confirmReturn = false
        confirmRestart = false
        if let shouldBeFullscreen = fullscreenBeforeGame {
            fullscreenBeforeGame = nil
            if windowIsFullscreen != shouldBeFullscreen { hostWindow?.toggleFullScreen(nil) }
        }
    }
}
