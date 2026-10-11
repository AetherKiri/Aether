import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var engine: EngineController

    private var developerMode: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["AETHER_HOST_DEVELOPER"] == "1" || env["AETHER_HOST_AUTORUN"] == "1"
    }

    var body: some View {
        Group {
            if developerMode { DeveloperContentView() }
            else { shell }
        }
        .onDisappear { model.closeActiveSession() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.closeActiveSession()
        }
    }

    private var shell: some View {
        Group {
            if model.activeVideo != nil { MediaView(model: model, media: model.media) }
            else if let game = model.activeGame {
                VStack(spacing: 0) {
                    HStack {
                        Button { model.confirmReturn = true } label: {
                            Label(model.text("back"), systemImage: "chevron.left")
                        }
                        Text(game.displayTitle).font(.headline)
                        Spacer()
                        Button { model.toggleFullscreen() } label: {
                            Label(model.text("fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        Button { model.showVirtualControls.toggle() } label: {
                            Label(model.text("virtualControls"), systemImage: "keyboard")
                        }
                        Button(model.text("enterText")) { model.showGameTextEntry = true }.disabled(engine.runtimeMovieActive)
                        Menu {
                            Toggle(model.text("logs"), isOn: $model.showLogs)
                            Button(model.text("folder")) { model.revealActiveGame() }
                            Button(model.text("restart")) { model.confirmRestart = true }.disabled(!model.canRestartGame)
                            Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }
                        } label: { Label(model.text("game"), systemImage: "ellipsis.circle") }
                        if engine.frameSize == .zero {
                            ProgressView().controlSize(.small)
                            Text(model.text("starting"))
                        }
                        if engine.translationStatus.state == .loading {
                            ProgressView().controlSize(.small)
                            Text(model.text("translationLoading")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12)
                    Divider()
                    HStack(spacing: 0) {
                        GameSurfaceView(engine: engine, language: model.language)
                        if model.showLogs {
                            Divider()
                            ScrollView {
                                Text(engine.logText).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.frame(width: 300)
                        }
                    }
                    if model.showVirtualControls {
                        Divider()
                        GameControlsView(model: model, engine: engine)
                    }
                }
            } else {
                NavigationSplitView {
                    shellSidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    Group {
                        switch model.route {
                        case .library: library
                        case .videos: videoLibrary
                        case .dashboard: dashboard
                        case .settings: ShellSettingsView(model: model)
                        }
                    }
                    .navigationTitle(model.text(model.route.textKey))
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .environment(\.locale, model.language.locale)
        .toolbar {
            ToolbarItemGroup {
                if model.activeGame == nil && model.activeVideo == nil && model.route != .settings {
                    if model.route == .videos {
                        Button { model.chooseVideo() } label: {
                            Label(model.text("importVideo"), systemImage: "plus")
                        }.help(model.text("importVideo")).disabled(!model.canOpenVideo)
                    } else {
                        Button { model.chooseImport() } label: {
                            Label(model.text("import"), systemImage: "plus")
                        }.help(model.text("import")).disabled(!model.canImport)
                        Button { model.chooseImport(external: true) } label: {
                            Label(model.text("linkGame"), systemImage: "link")
                        }.help(model.text("linkGame")).disabled(!model.canImport)
                    }
                    Button { model.refreshLibrary() } label: {
                        Label(model.text("refresh"), systemImage: "arrow.clockwise")
                    }.help(model.text("refresh")).disabled(!model.canNavigateShell)
                    if model.isImporting { ProgressView().controlSize(.small) }
                }
                Button { model.openSettings() } label: {
                    Label(model.text("settings"), systemImage: "gearshape")
                }.help(model.text("settings")).disabled(!model.canOpenSettings)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            engine.releaseVirtualKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            engine.releaseVirtualKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            model.refreshFullscreenState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            model.refreshFullscreenState()
        }
        .onAppear { model.refreshFullscreenState() }
        .modifier(PlatformDialogPresentation(dialogs: engine.platformDialogs, language: model.language))
        .sheet(isPresented: $model.showGameTextEntry) { GameTextEntryView(model: model) }
        .sheet(item: $model.renameGame) { _ in
            VStack(alignment: .leading, spacing: 16) {
                Text(model.text("rename")).font(.headline)
                TextField(model.text("gameTitle"), text: $model.renameTitle)
                if let error = model.renameError { Text(error).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button(model.text("cancel")) { model.renameGame = nil }.keyboardShortcut(.cancelAction)
                    Button(model.text("ok")) { model.saveRename() }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 400)
        }
        .confirmationDialog(model.text("remove"), isPresented: Binding(
            get: { model.removeGame != nil }, set: { if !$0 { model.removeGame = nil } }
        ), titleVisibility: .visible) {
            Button(model.text("remove"), role: .destructive) { model.removeSelectedGame() }
            Button(model.text("cancel"), role: .cancel) { model.removeGame = nil }
        } message: { Text(model.text("removeHelp")) }
        .confirmationDialog(model.text("unsavedTitle"), isPresented: $model.confirmDiscardSettings, titleVisibility: .visible) {
            Button(model.text("saveLeave")) { model.resolveSettingsNavigation(save: true) }
            Button(model.text("discardLeave"), role: .destructive) { model.resolveSettingsNavigation(save: false) }
            Button(model.text("continueEditing"), role: .cancel) { model.cancelSettingsNavigation() }
        } message: { Text(model.text("unsavedBody")) }
        .alert(model.text("error"), isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button(model.text("ok")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog(model.text("back"), isPresented: $model.confirmReturn, titleVisibility: .visible) {
            Button(model.text("back")) { model.returnToLibrary() }
            Button(model.text("continue"), role: .cancel) {}
        } message: { Text(model.text("backHelp")) }
        .confirmationDialog(model.text("restart"), isPresented: $model.confirmRestart, titleVisibility: .visible) {
            Button(model.text("restart"), role: .destructive) { model.restartActiveGame() }
            Button(model.text("continue"), role: .cancel) {}
        } message: { Text(model.text("restartHelp")) }
        .onChange(of: engine.failureMessage) { message in
            if let message, model.activeGame != nil {
                model.returnToLibrary()
                model.error = message == "Game startup failed." ? model.text("startFailed") : message
            }
        }
    }

    private var sidebarSelection: Binding<String?> {
        Binding(get: {
            if model.route == .library, let id = model.selection { return "game:" + id.uuidString }
            if model.route == .videos, let id = model.selectedVideoID { return "video:" + id.uuidString }
            return model.route.rawValue
        }, set: { value in
            guard model.canNavigateShell, let value else { return }
            if value.hasPrefix("game:"), let id = UUID(uuidString: String(value.dropFirst(5))) {
                model.selection = id; model.requestRoute(.library)
            } else if value.hasPrefix("video:"), let id = UUID(uuidString: String(value.dropFirst(6))) {
                model.selectedVideoID = id; model.requestRoute(.videos)
            } else if let route = ShellRoute(rawValue: value) { model.requestRoute(route) }
        })
    }

    private var shellSidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                Label(model.text("dashboard"), systemImage: "house").tag("dashboard")
                Label(model.text("library"), systemImage: "books.vertical").tag("library")
                Label(model.text("videoLibrary"), systemImage: "film").tag("videos")
                Label(model.text("settings"), systemImage: "gearshape").tag("settings")
            }
            if model.route == .library {
                Section(model.text("library")) {
                    ForEach(model.games) { game in
                        HStack(spacing: 10) {
                            if let cover = model.coverImage(for: game) {
                                Image(nsImage: cover).resizable().scaledToFill()
                                    .frame(width: 30, height: 40).clipped().cornerRadius(4)
                            } else {
                                Image(systemName: "gamecontroller").foregroundStyle(.secondary).frame(width: 30)
                            }
                            Text(game.displayTitle).lineLimit(2)
                        }.padding(.vertical, 3).tag("game:" + game.id.uuidString)
                            .contextMenu {
                                Button(model.text("rename")) { model.beginRename(game) }
                                Button(model.text("remove"), role: .destructive) { model.removeGame = game }
                            }
                    }
                }
            } else if model.route == .videos {
                Section(model.text("videoLibrary")) {
                    ForEach(model.videos) { video in
                        Label(video.displayTitle, systemImage: "film").lineLimit(2)
                            .tag("video:" + video.id.uuidString)
                            .contextMenu { Button(model.text("removeVideo"), role: .destructive) { model.removeVideo(video) } }
                    }
                }
            }
        }.listStyle(.sidebar)
    }

    private var videoLibrary: some View { VideoLibraryView(model: model) }

    private var dashboard: some View { DashboardView(model: model) }

    private var library: some View {
        Group {
            if let game = model.selectedGame {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let cover = model.coverImage(for: game) {
                            Image(nsImage: cover)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 360, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.tint)
                                .frame(height: 120)
                        }
                        Text(game.displayTitle).font(.largeTitle.bold()).textSelection(.enabled)
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            GridRow {
                                Text(model.text("imported")).foregroundStyle(.secondary)
                                Text(game.importedAt, style: .date)
                            }
                            GridRow {
                                Text(model.text("played")).foregroundStyle(.secondary)
                                if let last = game.lastPlayedAt { Text(last, style: .date) }
                                else { Text(model.text("never")) }
                            }
                        }
                        Text(model.text(game.isExternal ? "externalStorage" : "managedStorage")).foregroundStyle(.secondary)
                        if game.isExternal { Text(model.text("linkHelp")).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button { model.play() } label: { Label(model.text("play"), systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canPlay)
                            Button(model.text("folder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([model.repository.gameURL(game)])
                            }
                        }
                        Menu {
                            Button(model.text("setCover")) { model.chooseCover() }.disabled(!model.canEditCover)
                            if model.coverImage(for: game) != nil {
                                Button(model.text("clearCover")) { model.clearSelectedCover() }.disabled(!model.canEditCover)
                            }
                            Divider()
                            Button(model.text("rename")) { model.beginRename(game) }.disabled(!model.canImport)
                            Button(model.text("remove"), role: .destructive) { model.removeGame = game }.disabled(!model.canImport)
                        } label: { Label(model.text("manage"), systemImage: "ellipsis.circle") }
                        .fixedSize()
                    }.frame(maxWidth: 600, alignment: .leading).padding(32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "books.vertical").font(.system(size: 64)).foregroundStyle(.secondary)
                    Text(model.text(model.games.isEmpty ? "empty" : "choose")).font(.title.bold())
                    Text(model.text("emptyHelp")).foregroundStyle(.secondary)
                    if model.isImporting {
                        ProgressView(model.text("importing"))
                    } else {
                        Button(model.text("import")) { model.chooseImport() }
                            .buttonStyle(.borderedProminent).disabled(!model.canImport)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
            }
        }
    }
}

private struct VideoLibraryView: View {
    @ObservedObject var model: ShellModel

    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    var body: some View {
        Group {
            if let video = model.videos.first(where: { $0.id == model.selectedVideoID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "film.stack").font(.system(size: 64)).foregroundStyle(.tint)
                        Text(video.displayTitle).font(.title.bold()).textSelection(.enabled)
                        if FileManager.default.fileExists(atPath: video.url.path) {
                            Text(video.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            let progress = model.storedVideoProgress(for: video)
                            if progress > 0 { Text(model.text("videoPosition") + ": " + time(progress)).foregroundStyle(.secondary) }
                            HStack {
                                Button { model.openVideo(video.url) } label: { Label(model.text("videoPlay"), systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent)
                                Button(model.text("removeVideo"), role: .destructive) { model.removeVideo(video) }
                            }
                        } else {
                            Text(model.text("videoMissing")).foregroundStyle(.red)
                            Button(model.text("removeVideo"), role: .destructive) { model.removeVideo(video) }
                        }
                    }.frame(maxWidth: 600, alignment: .leading).padding(32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "film.stack").font(.system(size: 64)).foregroundStyle(.secondary)
                    Text(model.text("emptyVideos")).font(.title.bold())
                    Text(model.text("emptyVideosHelp")).foregroundStyle(.secondary)
                    Button(model.text("importVideo")) { model.chooseVideo() }
                        .buttonStyle(.borderedProminent).disabled(!model.canOpenVideo)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
            }
        }

    }
}

private struct DashboardView: View {
    @ObservedObject var model: ShellModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(model.text("dashboard")).font(.largeTitle.bold())
                HStack(spacing: 16) {
                    Button { model.showLibrary() } label: {
                        DashboardStat(title: String(format: model.text("gamesCount"), model.games.count), icon: "gamecontroller.fill")
                    }.buttonStyle(.plain)
                    Button { model.showVideos() } label: {
                        DashboardStat(title: String(format: model.text("videosCount"), model.videos.count), icon: "film.fill")
                    }.buttonStyle(.plain)
                }
                Divider()
                Text(model.text("recentGames")).font(.title2.bold())
                if let game = model.games.compactMap({ game in game.lastPlayedAt.map { (game, $0) } }).sorted(by: { $0.1 > $1.1 }).first?.0 {
                    HStack {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(.tint)
                        Text(game.displayTitle)
                        Spacer()
                        Button(model.text("play")) { model.selection = game.id; model.play() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text(model.text("never")).foregroundStyle(.secondary)
                }
                Button(model.text("openLibrary")) { model.showLibrary() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DashboardStat: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon).font(.title3).padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ShellCommands: Commands {
    @ObservedObject var model: ShellModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.text("import")) { model.chooseImport() }.keyboardShortcut("o").disabled(!model.canImport)
            Button(model.text("linkGame")) { model.chooseImport(external: true) }.disabled(!model.canImport)
            Divider()
            Button(model.text("refresh")) { model.refreshLibrary() }.keyboardShortcut("r").disabled(!model.canNavigateShell)
        }
        CommandGroup(replacing: .appSettings) {
            Button(model.text("settings") + "…") { model.openSettings() }
                .keyboardShortcut(",").disabled(!model.canOpenSettings)
        }
        CommandGroup(after: .sidebar) {
            Button(model.text("visualNovels")) { model.showLibrary() }.keyboardShortcut("1").disabled(!model.canNavigateShell)
            Button(model.text("videoLibrary")) { model.showVideos() }.keyboardShortcut("2").disabled(!model.canNavigateShell)
            Button(model.text("dashboard")) { model.showDashboard() }.keyboardShortcut("3").disabled(!model.canNavigateShell)
            Divider()
            Toggle(model.text("fullscreen"), isOn: Binding(
                get: { model.isFullscreen },
                set: { _ in model.toggleFullscreen() }
            ))
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(model.activeGame == nil)
        }
        CommandMenu(model.text("video")) {
            Button(model.text("openVideo") + "…") { model.chooseVideo() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.canOpenVideo)
            Button(model.text("back")) { model.closeVideo() }.disabled(model.activeVideo == nil)
        }
        CommandMenu(model.text("game")) {
            Toggle(model.text("virtualControls"), isOn: $model.showVirtualControls)
                .disabled(model.activeGame == nil)
            Button(model.text("enterText")) { model.showGameTextEntry = true }.disabled(model.activeGame == nil || model.engine.runtimeMovieActive)
            Toggle(model.text("logs"), isOn: $model.showLogs).disabled(model.activeGame == nil)
            Button(model.text("folder")) { model.revealActiveGame() }.disabled(model.activeGame == nil)
            Divider()
            Button(model.text("play")) { model.play() }.disabled(!model.canPlay)
            Button(model.text("restart")) { model.confirmRestart = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canRestartGame)
            Button(model.text("back")) { model.confirmReturn = true }.keyboardShortcut("l").disabled(model.activeGame == nil)
            Divider()
            Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }.keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandGroup(after: .help) {
            Button(model.text("qqGroup")) { model.openQQGroup() }
        }
    }
}
