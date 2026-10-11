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
            } else { library }
        }
        .environment(\.locale, model.language.locale)
        .toolbar {
            ToolbarItemGroup {
                if model.activeGame == nil && model.activeVideo == nil {
                    Button { model.chooseVideo() } label: {
                        Label(model.text("openVideo"), systemImage: "film")
                    }.disabled(!model.canOpenVideo)
                    Button { model.chooseImport() } label: {
                        Label(model.text("import"), systemImage: "plus")
                    }.disabled(!model.canImport)
                    Button { model.chooseImport(external: true) } label: {
                        Label(model.text("linkGame"), systemImage: "link")
                    }.disabled(!model.canImport)
                    if model.isImporting { ProgressView().controlSize(.small) }
                }
                Button { model.showSettings = true } label: {
                    Label(model.text("settings"), systemImage: "gearshape")
                }
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
        .sheet(isPresented: $model.showSettings) { ShellSettingsView(model: model) }
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

    private var library: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.games) { game in
                    HStack(spacing: 10) {
                        if let cover = model.coverImage(for: game) {
                            Image(nsImage: cover)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 34, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: game.isExternal ? "link" : "gamecontroller")
                                .frame(width: 34, height: 44)
                                .foregroundStyle(.tint)
                        }
                        Text(game.displayTitle).lineLimit(2)
                    }.tag(game.id)
                        .contextMenu {
                            Button(model.text("rename")) { model.beginRename(game) }.disabled(!model.canImport)
                            Button(model.text("remove")) { model.removeGame = game }.disabled(!model.canImport)
                        }
                }
            }
            .navigationTitle(model.text("library"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let game = model.selectedGame {
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
                    HStack {
                        Button(model.text("setCover")) { model.chooseCover() }.disabled(!model.canEditCover)
                        if model.coverImage(for: game) != nil {
                            Button(model.text("clearCover")) { model.clearSelectedCover() }.disabled(!model.canEditCover)
                        }
                    }
                    HStack {
                        Button(model.text("rename")) { model.beginRename(game) }.disabled(!model.canImport)
                        Button(model.text("remove")) { model.removeGame = game }.disabled(!model.canImport)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(32)
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

struct ShellSettingsView: View {
    @ObservedObject var model: ShellModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.text("settings")).font(.title2.bold())
            Form {
                Picker(model.text("language"), selection: $model.language) {
                    ForEach(ShellLanguage.allCases) { Text($0.name).tag($0) }
                }
                Picker(model.text("renderer"), selection: $model.renderer) {
                    Text(model.text("software")).tag("software")
                    Text(model.text("metal")).tag("metal")
                }
                Text(model.text("rendererHelp")).font(.caption).foregroundStyle(.secondary)
                Toggle(model.text("virtualControls"), isOn: $model.showVirtualControls)
                Text(model.text("virtualControlsHelp")).font(.caption).foregroundStyle(.secondary)
                Toggle(model.text("logs"), isOn: $model.showLogs)
            }
            if model.translationAvailable { translationSection }
            Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }
            Divider()
            Text(model.text("storage")).font(.headline)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            HStack {
                Spacer()
                Button(model.text("ok")) { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { if model.translationAvailable { model.engine.refreshTranslationStatus() } }
    }

    /// Local-model translation, mirroring the Godot shell's compatibility row:
    /// a model path plus the interface language as the translation target.
    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text("translationModel")).font(.headline)
            Text(model.text("translationModelHelp")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.text("translationModelSelect")) { model.chooseTranslationModel() }
                if model.translationSettings.isConfigured {
                    Button(model.text("translationModelClear")) { model.clearTranslationModel() }
                }
            }
            if model.translationSettings.isConfigured {
                Text(model.text("translationModelSelected") + ": " + model.translationSettings.displayName)
                    .font(.caption).textSelection(.enabled)
                Text(model.text("translationModelClearDesc")).font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.text("translationTargetHelp")).font(.caption2).foregroundStyle(.secondary)
            Text(model.engine.translationStatus.summary(model.text))
                .font(.caption)
                .foregroundStyle(model.engine.translationStatus.state == .failed ? .red : .secondary)
            translationDetail
        }
    }

    @ViewBuilder
    private var translationDetail: some View {
        let detail = model.engine.translationStatus.detail(model.text)
        if !detail.isEmpty {
            Text(detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct ShellCommands: Commands {
    @ObservedObject var model: ShellModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.text("import")) { model.chooseImport() }.keyboardShortcut("o").disabled(!model.canImport)
            Button(model.text("linkGame")) { model.chooseImport(external: true) }.disabled(!model.canImport)
        }
        CommandGroup(replacing: .appSettings) {
            Button(model.text("settings") + "…") { model.showSettings = true }.keyboardShortcut(",")
        }
        CommandMenu(model.text("video")) {
            Button(model.text("openVideo") + "…") { model.chooseVideo() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.canOpenVideo)
            Button(model.text("back")) { model.closeVideo() }.disabled(model.activeVideo == nil)
        }
        CommandMenu(model.text("game")) {
            Toggle(model.text("fullscreen"), isOn: Binding(
                get: { model.isFullscreen },
                set: { _ in model.toggleFullscreen() }
            ))
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(model.activeGame == nil)
            Toggle(model.text("virtualControls"), isOn: $model.showVirtualControls)
                .disabled(model.activeGame == nil)
            Button(model.text("enterText")) { model.showGameTextEntry = true }.disabled(model.activeGame == nil || model.engine.runtimeMovieActive)
            Toggle(model.text("logs"), isOn: $model.showLogs).disabled(model.activeGame == nil)
            Button(model.text("folder")) { model.revealActiveGame() }.disabled(model.activeGame == nil)
            Divider()
            Button(model.text("play")) { model.play() }.keyboardShortcut("r").disabled(!model.canPlay)
            Button(model.text("restart")) { model.confirmRestart = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canRestartGame)
            Button(model.text("back")) { model.confirmReturn = true }.keyboardShortcut("l").disabled(model.activeGame == nil)
            Divider()
            Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }.keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
