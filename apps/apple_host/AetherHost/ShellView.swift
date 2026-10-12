import AppKit
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
        VStack(spacing: 0) {
            if model.sceneTestActive {
                HStack(spacing: 10) {
                    Label(model.text("sceneTestMode"), systemImage: "testtube.2")
                    Spacer()
                    Button(model.text("sceneTestExit")) { model.exitSceneTest() }
                }
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(palette.accent.color.opacity(palette.dark ? 0.18 : 0.10))
                Divider()
            }
            Group {
                if developerMode { DeveloperContentView() }
                else { shell }
            }
        }
        .onAppear { model.applySceneTestIfRequested() }
        .onDisappear { model.closeActiveSession() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.closeActiveSession()
        }
        .sheet(isPresented: Binding(get: { model.legalGateRequired }, set: { _ in })) {
            LegalAgreementView(language: model.language,
                               accept: { model.acceptLegalAgreement() },
                               decline: { model.declineLegalAgreement() })
                .interactiveDismissDisabled()
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
                            Toggle(model.text("consoleTitle"), isOn: $model.showDiagnosticsConsole)
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
                    if !engine.renderState.fallbacks.isEmpty {
                        RenderingStatusView(engine: engine, language: model.language).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    Divider()
                    HStack(spacing: 0) {
                        ZStack(alignment: .topTrailing) {
                            GameSurfaceView(engine: engine, language: model.language)
                            if model.showVirtualControls {
                                GameControlsView(model: model, engine: engine)
                            }
                        }
                        if model.showDiagnosticsConsole {
                            Divider()
                            DiagnosticsConsoleView(model: model, engine: engine)
                                .frame(width: 380)
                                .onAppear { engine.diagnosticsConsoleActive = true }
                                .onDisappear { engine.diagnosticsConsoleActive = false }
                        } else if model.showLogs {
                            Divider()
                            ScrollView {
                                Text(engine.logText).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.frame(width: 300)
                        }
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
        .confirmationDialog(model.text(model.removeGameIsBuiltin ? "deleteBuiltin" : "remove"), isPresented: Binding(
            get: { model.removeGame != nil }, set: { if !$0 { model.removeGame = nil } }
        ), titleVisibility: .visible) {
            Button(model.text(model.removeGameIsBuiltin ? "deleteBuiltin" : "remove"), role: .destructive) { model.removeSelectedGame() }
            Button(model.text("cancel"), role: .cancel) { model.removeGame = nil }
        } message: { Text(model.text(model.removeGameIsBuiltin ? "deleteBuiltinBody" : "removeHelp")) }
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

    private var stats: PlayStats {
        var calendar = Calendar.current
        calendar.locale = model.language.locale
        return PlayStats(games: model.games, now: Date(), calendar: calendar)
    }

    private var greetingKey: String {
        PlayStats.greetingKey(hour: Calendar.current.component(.hour, from: Date()))
    }

    var body: some View {
        let stats = self.stats
        // Godot switches the dashboard to a compact layout below 860 pt.
        GeometryReader { geometry in
            let compact = geometry.size.width < 860
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero(stats, compact: compact)
                    statGrid(stats, compact: compact)
                    weekTrail(stats, compact: compact)
                    if let spotlight = stats.spotlight {
                        if compact {
                            continueCard(spotlight)
                            rankedList(stats)
                        } else {
                            HStack(alignment: .top, spacing: 20) {
                                continueCard(spotlight)
                                rankedList(stats)
                            }
                        }
                    } else {
                        rankedList(stats)
                    }
                    recentList(stats)
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(compact ? 20 : 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Hero

    private func hero(_ stats: PlayStats, compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 20) { rings(stats); heroCopy(stats) }
            } else {
                HStack(alignment: .center, spacing: 36) {
                    rings(stats)
                    heroCopy(stats)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private func heroCopy(_ stats: PlayStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AETHERKIRI · " + model.text("dashTitle"))
                .font(.caption.weight(.semibold)).foregroundStyle(palette.accentText.color)
            Text(model.text(greetingKey)).font(.system(size: 30, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle(stats)).font(.callout).foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                legendRow(model.text("dashRingMilestone"), String(format: model.text("dashMilestone"), stats.nextMilestoneHours),
                          value: "\(Int((stats.milestoneProgress * 100).rounded()))%", tone: palette.accent.color)
                legendRow(model.text("dashRingLibrary"), model.text("dashCompletion"),
                          value: "\(stats.playedCount) / \(stats.gamesCount)", tone: palette.accent2.color)
                legendRow(model.text("dashRingDays"), model.text("dashWeekTrail"),
                          value: "\(stats.activeDays) / 7", tone: palette.success.color)
            }
            .padding(.top, 4)
            Button(model.text("dashOpenLibrary")) { model.showLibrary() }
                .lumenPrimaryAction()
                .padding(.top, 6)
        }
    }

    private func rings(_ stats: PlayStats) -> some View {
        ZStack {
            DashboardRing(progress: stats.milestoneProgress, color: palette.accent.color, lineWidth: 10, diameter: 216)
            DashboardRing(progress: stats.libraryProgress, color: palette.accent2.color, lineWidth: 10, diameter: 176)
            DashboardRing(progress: stats.daysProgress, color: palette.success.color, lineWidth: 10, diameter: 136)
            VStack(spacing: 0) {
                Text("\(stats.totalHoursWhole)").font(.system(size: 40, weight: .semibold, design: .rounded))
                Text(model.text("dashHours") + " · " + String(format: model.text("dashMinutes"), stats.totalMinutesRemainder))
                    .font(.caption).foregroundStyle(palette.secondary.color)
            }
        }
        .frame(width: 216, height: 216)
    }

    private func legendRow(_ name: String, _ hint: String, value: String, tone: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(tone).frame(width: 8, height: 8)
            Text(name).font(.callout)
            Text(hint).font(.caption).foregroundStyle(palette.secondary.color).lineLimit(1)
            Spacer(minLength: 12)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func subtitle(_ stats: PlayStats) -> String {
        stats.totalSeconds >= 60
            ? String(format: model.text("dashSubtitleStats"), stats.playedCount, PlayStats.duration(stats.totalSeconds))
            : model.text("dashSubtitle")
    }

    // MARK: - Cards

    private func statGrid(_ stats: PlayStats, compact: Bool) -> some View {
        // Godot: two columns in the compact layout, four when wide.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: compact ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: 16) {
            DashboardStat(title: model.text("dashGames"), value: "\(stats.gamesCount)", icon: "books.vertical", tone: palette.accent.color)
            DashboardStat(title: model.text("dashPlayed"), value: "\(stats.playedCount)", icon: "play.circle", tone: palette.accent2.color)
            DashboardStat(title: model.text("dashWeek"), value: "\(stats.weekCount)", icon: "calendar", tone: palette.success.color)
            DashboardStat(title: model.text("dashAverage"), value: PlayStats.duration(stats.averageSeconds), icon: "clock", tone: palette.accent3.color)
        }
    }

    private func weekTrail(_ stats: PlayStats, compact: Bool) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.locale = model.language.locale
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: compact ? 4 : 7)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.text("dashWeekTrail")).font(.title3.bold())
                Spacer()
                Text(String(format: model.text("dashWeekSummary"), stats.activeDays))
                    .font(.caption).foregroundStyle(palette.secondary.color)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(0..<stats.dayTrail.count, id: \.self) { index in
                    let date = calendar.date(byAdding: .day, value: index - (stats.dayTrail.count - 1), to: today) ?? today
                    dayChip(date: date, weekday: formatter.string(from: date), titles: stats.dayTrail[index])
                }
            }
        }
    }

    private func dayChip(date: Date, weekday: String, titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(weekday).font(.caption).foregroundStyle(palette.secondary.color)
                Text("\(Calendar.current.component(.day, from: date))").font(.caption.monospacedDigit())
            }
            if titles.isEmpty {
                Text(model.text("dashDayIdle")).font(.caption2).foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(titles.prefix(2), id: \.self) { title in
                    Text(title).font(.caption2).lineLimit(1).truncationMode(.tail)
                }
                if titles.count > 2 {
                    Text("+\(titles.count - 2)").font(.caption2).foregroundStyle(palette.secondary.color)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(10)
        .background(palette.raised.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(titles.isEmpty ? Color.clear : palette.accent.color.opacity(0.35), lineWidth: 1))
    }

    private func continueCard(_ spotlight: PlayStats.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text("dashContinueEyebrow")).font(.caption.weight(.semibold)).foregroundStyle(palette.accentText.color)
            HStack(alignment: .top, spacing: 14) {
                if let game = model.games.first(where: { $0.id == spotlight.id }), let image = model.coverImage(for: game) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 112).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(spotlight.title).font(.title3.bold()).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(String(format: model.text("dashPlayedLabel"), PlayStats.duration(spotlight.seconds)))
                        .font(.caption).foregroundStyle(palette.secondary.color)
                    Button(model.text("dashContinue")) { play(spotlight.id) }
                        .lumenPrimaryAction()
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private func rankedList(_ stats: PlayStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text("dashTop")).font(.title3.bold())
            if stats.ranked.isEmpty {
                Text(model.text("dashEmpty")).font(.caption).foregroundStyle(palette.secondary.color)
            } else {
                ForEach(Array(stats.ranked.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.callout.monospacedDigit())
                            .foregroundStyle(palette.secondary.color).frame(width: 20, alignment: .trailing)
                        Text(entry.title).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(PlayStats.duration(entry.seconds)).font(.caption.monospacedDigit())
                            .foregroundStyle(palette.secondary.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private func recentList(_ stats: PlayStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text("recentGames")).font(.title3.bold())
            if stats.recent.isEmpty {
                Text(model.text("dashEmpty")).font(.caption).foregroundStyle(palette.secondary.color)
            } else {
                ForEach(stats.recent, id: \.id) { entry in
                    HStack(spacing: 10) {
                        Text(entry.title).lineLimit(1)
                        Spacer(minLength: 12)
                        if entry.seconds > 0 {
                            Text(String(format: model.text("dashPlayedLabel"), PlayStats.duration(entry.seconds)))
                                .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary.color)
                        }
                        if let date = entry.lastPlayed {
                            Text(date, style: .date).font(.caption).foregroundStyle(palette.secondary.color)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private func play(_ id: UUID) {
        model.selection = id
        model.play()
    }
}

private struct DashboardRing: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct DashboardStat: View {
    @Environment(\.shellPalette) private var palette
    let title: String
    let value: String
    let icon: String
    let tone: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(tone)
                .frame(width: 34, height: 34)
                .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(palette.secondary.color).lineLimit(1)
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
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
