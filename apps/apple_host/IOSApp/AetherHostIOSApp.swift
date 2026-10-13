import SwiftUI

@main
struct AetherHostIOSApp: App {
    @StateObject private var shell: MobileShellState
    @StateObject private var library: MobileLibraryState
    init() {
        let state=MobileShellState()
        _shell=StateObject(wrappedValue:state)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ios-library-preview") {
            let fixture=FileManager.default.temporaryDirectory.appendingPathComponent("AetherLibraryPreview-" + UUID().uuidString)
            _library=StateObject(wrappedValue:MobileLibraryState(supportRoot:fixture.appendingPathComponent("Support"),gamesRoot:fixture.appendingPathComponent("Games"),initialLoad:state.canPlay))
        } else {
            _library=StateObject(wrappedValue:MobileLibraryState(supportRoot:state.supportRoot,gamesRoot:state.gamesRoot,initialLoad:state.canPlay))
        }
        #else
        _library=StateObject(wrappedValue:MobileLibraryState(supportRoot:state.supportRoot,gamesRoot:state.gamesRoot,initialLoad:state.canPlay))
        #endif
    }
    var body: some Scene {
        WindowGroup { MobileRootView(shell: shell, library: library) }
    }
}

struct MobileRootView: View {
    @ObservedObject var shell: MobileShellState
    @ObservedObject var library: MobileLibraryState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var destination: String?="home"
    @State private var game: MobileGameRoute?
    @State private var document: SettingsDocument?
    var body: some View {
        Group {
            if shell.canPlay {productNavigation}
            else {NavigationStack {legalContent.toolbar {languageToolbar}}}
        }
            .alert(shell.language.text("error"), isPresented: Binding(get: { shell.error != nil }, set: { if !$0 { shell.error = nil } })) {
                Button(shell.language.text("ok")) { shell.error = nil }
            } message: { Text(shell.error ?? "") }
            .sheet(item: $document) { item in
                NavigationStack {
                    ScrollView { Text(item.contents(language: shell.language) ?? shell.language.text("documentUnavailable")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle(shell.language.text(item.titleKey))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(shell.language.text("ok")) { document = nil }.frame(minHeight: 44) } }
                }
            }
            .fullScreenCover(item: $game) { route in MobileGameView(route: route, language: shell.language) { game = nil } }
        .environment(\.locale, shell.language.locale)
        .onChange(of: shell.canPlay) { _, allowed in if allowed {library.reload()} }
        .onAppear {
            #if DEBUG
            if LegalAgreement.bypassRequested(), ProcessInfo.processInfo.arguments.contains("--ios-library-preview") {
                Task {
                    do {
                        let source=library.library.root.deletingLastPathComponent().appendingPathComponent("Fixture Demo")
                        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
                        let packed=source.appendingPathComponent("data.xp3")
                        if !FileManager.default.fileExists(atPath:packed.path) {
                            guard let bundled=Bundle.main.url(forResource:"data",withExtension:"xp3") else {throw CocoaError(.fileNoSuchFile)}
                            try FileManager.default.copyItem(at:bundled,to:packed)
                        }
                        await library.importURL(source); destination="library"
                    } catch {shell.error=error.localizedDescription}
                }
            }
            if LegalAgreement.bypassRequested(), ProcessInfo.processInfo.arguments.contains("--ios-demo-smoke"), game == nil {
                do { game = MobileGameRoute(url: try shell.prepareDemo()) }
                catch { shell.error = error.localizedDescription }
            }
            #endif
        }
    }
    private var languageToolbar: some ToolbarContent {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(shell.language.text("language"), selection: $shell.language) {
                            ForEach(ShellLanguage.allCases) { language in Text(language.name).tag(language) }
                        }
                    } label: { Label(shell.language.text("language"), systemImage: "globe").frame(minWidth: 44, minHeight: 44) }
                }
    }
    private var legalContent: some View {
        Group {
                if shell.declined {
                    ContentUnavailableView {
                        Label(shell.language.text("mobileDeclined"), systemImage: "hand.raised")
                    } description: {
                        Text(shell.language.text("mobileDeclinedBody"))
                    } actions: {
                        Button(shell.language.text("mobileReviewAgain")) { shell.reviewAgain() }.frame(minHeight: 44)
                    }
                } else if let required = shell.requiredDocument {
                    agreement(required)
                }
        }
    }
    private var productNavigation: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(selection:$destination) {
                        Label(shell.language.text("dashboard"),systemImage:"house").tag("home")
                        Label(shell.language.text("library"),systemImage:"books.vertical").tag("library")
                    }.navigationTitle("Aether")
                } detail: {NavigationStack {if destination=="library" {libraryPage} else {home.toolbar {languageToolbar}}}}
            } else {
                TabView(selection:$destination) {
                    NavigationStack {home.toolbar {languageToolbar}}.tabItem {Label(shell.language.text("dashboard"),systemImage:"house")}.tag("home")
                    NavigationStack {libraryPage}.tabItem {Label(shell.language.text("library"),systemImage:"books.vertical")}.tag("library")
                }
            }
        }
    }
    private var libraryPage: some View {
        MobileLibraryView(model:library,shell:shell) { item in
            game=MobileGameRoute(url:library.library.gameURL(item),title:item.displayTitle)
        }
    }
    private var home: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Aether Demo", systemImage: "book.pages").font(.title2)
                    Text(shell.language.text("builtinDemo")).foregroundStyle(.secondary)
                    Button(shell.language.text("play")) {
                        do { game = MobileGameRoute(url: try shell.prepareDemo()) }
                        catch { shell.error = error.localizedDescription }
                    }.disabled(library.isImporting || library.isEditingCover).buttonStyle(.borderedProminent).frame(minHeight: 44)
                }.padding(.vertical, 8)
            }
            Section(shell.language.text("aboutSection")) {
                ForEach([SettingsDocument.privacy, .statement, .license, .additionalLicense, .thirdParty]) { item in
                    Button(shell.language.text(item.titleKey)) { document = item }.frame(minHeight: 44)
                }
            }
        }.navigationTitle(shell.language.text("dashboard"))
    }
    private func agreement(_ required: LegalDocument) -> some View {
        let body = required.settingsDocument.contents(language: shell.language)
        return VStack(alignment: .leading, spacing: 16) {
            Text(shell.language.text(required.titleKey)).font(.title2.bold())
            ScrollView { Text(body ?? shell.language.text("documentUnavailable")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            ViewThatFits(in: .horizontal) {
                HStack { declineButton; Spacer(); acceptButton(body != nil) }
                VStack(alignment: .leading) { acceptButton(body != nil); declineButton }
            }
        }.padding()
    }
    private var declineButton: some View {
        Button(shell.language.text("legalDecline")) { shell.decline() }.frame(minHeight: 44)
    }
    private func acceptButton(_ readable: Bool) -> some View {
        Button(shell.language.text("legalAccept")) { shell.acceptDocument() }
            .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(!readable)
    }
}

struct MobileGameRoute: Identifiable {
    let id = UUID()
    let url: URL
    var title="Aether Demo"
}
@MainActor
final class MobileGameViewModel: ObservableObject {
    let controller: AetherMobileGameController
    @Published var status = ""
    @Published var fallbackKey: String?
    @Published var error: String?
    init(url: URL) {
        controller = AetherMobileGameController(gameURL: url)
        controller.statusChanged = { [weak self] in self?.status = $0 }
        controller.failed = { [weak self] in self?.error = $0 }
        controller.presentationFallback = { [weak self] in self?.fallbackKey = $0 }
    }
}
struct MobileGameSurface: UIViewControllerRepresentable {
    let controller: AetherMobileGameController
    func makeUIViewController(context: Context) -> AetherMobileGameController { controller }
    func updateUIViewController(_ controller: AetherMobileGameController, context: Context) {}
    static func dismantleUIViewController(_ controller: AetherMobileGameController, coordinator: ()) { controller.stop() }
}
struct MobileGameView: View {
    @StateObject private var game: MobileGameViewModel
    let language: ShellLanguage
    let close: () -> Void
    let title: String
    @State private var confirmReturn = false
    init(route: MobileGameRoute, language: ShellLanguage, close: @escaping () -> Void) {
        _game = StateObject(wrappedValue: MobileGameViewModel(url: route.url))
        self.language=language; self.close=close; self.title=route.title
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    Button { confirmReturn = true } label: { Label(language.text("mobileBackHome"), systemImage: "chevron.left") }.frame(minWidth: 44, minHeight: 44)
                    Text(title).font(.headline)
                    Button(language.text("enterKey")) { game.controller.sendEnter() }.frame(minWidth: 44, minHeight: 44)
                    Button(language.text("mobileResumeAudio")) { game.controller.resumeAudio() }.frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.bordered).padding(.horizontal).frame(minHeight: 52)
            }
            if let key = game.fallbackKey { Text(language.text(key)).font(.caption).padding(.horizontal) }
            MobileGameSurface(controller: game.controller)
            Text(game.status == "paused" ? language.text("mobilePaused") : game.status == "running" ? language.text("mobileRunning") : game.status == "restartRequired" ? language.text("mobileAudioRestart") : game.status)
                .font(.caption).frame(minHeight: 24).foregroundStyle(.secondary)
        }.background(Color.black).foregroundStyle(.white)
        .confirmationDialog(language.text("mobileBackHome"), isPresented: $confirmReturn) {
            Button(language.text("mobileBackHome")) { game.controller.stop(); close() }
            Button(language.text("continue"), role: .cancel) {}
        }
        .alert(language.text("error"), isPresented: Binding(get: { game.error != nil }, set: { if !$0 { game.error=nil } })) {
            Button(language.text("ok")) { game.controller.stop(); close() }
        } message: { Text(game.error ?? "") }
        .onChange(of: confirmReturn) { _, presented in game.controller.setSystemModalPresented(presented) }
        .onDisappear { game.controller.stop() }
    }
}
