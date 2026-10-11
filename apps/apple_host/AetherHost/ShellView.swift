import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var engine: EngineController
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: ThemePalette {
        contrast == .increased ? model.settings.palette.increasedContrast() : model.settings.palette
    }

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
                            Text(model.text("translationLoading")).font(.caption).foregroundStyle(palette.secondary.color)
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
                        .scrollContentBackground(.hidden).background(palette.raised.color)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background.color)
                    .navigationTitle(model.text(model.route.textKey))
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .environment(\.locale, model.language.locale)
        .environment(\.shellPalette, palette)
        .foregroundStyle(palette.primary.color)
        .tint(palette.accent.color)
        .preferredColorScheme(palette.dark ? .dark : .light)
        .groupBoxStyle(LumenGroupBoxStyle())
        .toolbar {
            ToolbarItemGroup {
                if model.activeGame == nil && model.activeVideo == nil && model.route == .dashboard {
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
                if let error = model.renameError { Text(error).foregroundStyle(palette.danger.color).font(.caption) }
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
        .confirmationDialog(model.text("removeVideo"), isPresented: Binding(
            get: { model.pendingVideoRemoval != nil }, set: { if !$0 { model.pendingVideoRemoval = nil } }
        ), titleVisibility: .visible) {
            Button(model.text("removeVideo"), role: .destructive) {
                if let video = model.pendingVideoRemoval { model.removeVideo(video) }
            }
            Button(model.text("cancel"), role: .cancel) { model.pendingVideoRemoval = nil }
        } message: { Text(model.text("removeVideoHelp")) }
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
        Binding(get: { model.route.rawValue }, set: { value in
            guard let value, let route = ShellRoute(rawValue: value) else { return }
            if route == .library { model.showLibrary() }
            else { model.requestRoute(route) }
        })
    }

    private var shellSidebar: some View {
        List(selection: sidebarSelection) {
            Label(model.text("dashboard"), systemImage: "house").tag("dashboard")
            Label(model.text("library"), systemImage: "books.vertical").tag("library")
            Label(model.text("videoLibrary"), systemImage: "film").tag("videos")
            Label(model.text("settings"), systemImage: "gearshape").tag("settings")
        }.listStyle(.sidebar)
    }

    private var videoLibrary: some View { VideoLibraryView(model: model) }

    private var dashboard: some View { DashboardView(model: model) }

    private var library: some View { GameLibraryView(model: model) }
}

private struct DashboardView: View {
    @Environment(\.shellPalette) private var palette
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
                            .lumenPrimaryAction()
                    }
                } else {
                    Text(model.text("never")).foregroundStyle(palette.secondary.color)
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
    @Environment(\.shellPalette) private var palette
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon).font(.title3).padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8))
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
