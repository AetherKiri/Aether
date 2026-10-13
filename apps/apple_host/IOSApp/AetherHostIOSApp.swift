import SwiftUI

@main
struct AetherHostIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @StateObject private var shell: MobileShellState
    @StateObject private var library: MobileLibraryState
    @StateObject private var preferences: MobilePreferencesState
    init() {
        #if DEBUG
        let fixture=(ProcessInfo.processInfo.arguments.contains("--ios-library-preview") || ProcessInfo.processInfo.arguments.contains("--ios-settings-preview")) ? FileManager.default.temporaryDirectory.appendingPathComponent("AetherLibraryPreview-" + UUID().uuidString) : nil
        #else
        let fixture: URL? = nil
        #endif
        let state=MobileShellState(supportRoot:fixture?.appendingPathComponent("Support"),gamesRoot:fixture?.appendingPathComponent("Games"))
        let preferences=MobilePreferencesState(root:state.supportRoot)
        state.language=preferences.settings.host.language
        _preferences=StateObject(wrappedValue:preferences)
        _shell=StateObject(wrappedValue:state)
        #if DEBUG
        if let fixture {
            _library=StateObject(wrappedValue:MobileLibraryState(supportRoot:fixture.appendingPathComponent("Support"),gamesRoot:fixture.appendingPathComponent("Games"),initialLoad:state.canPlay))
        } else {
            _library=StateObject(wrappedValue:MobileLibraryState(supportRoot:state.supportRoot,gamesRoot:state.gamesRoot,initialLoad:state.canPlay))
        }
        #else
        _library=StateObject(wrappedValue:MobileLibraryState(supportRoot:state.supportRoot,gamesRoot:state.gamesRoot,initialLoad:state.canPlay))
        #endif
    }
    var body: some Scene {
        WindowGroup { MobileRootView(shell: shell, library: library, preferences: preferences) }
    }
}

struct MobileRootView: View {
    @ObservedObject var shell: MobileShellState
    @ObservedObject var library: MobileLibraryState
    @ObservedObject var preferences: MobilePreferencesState
    @State private var pendingDestination: String?
    private var palette: ThemePalette {preferences.settings.host.palette}
    private var selection: Binding<String?> {Binding(get:{destination},set:{requested in
        guard requested != destination else {return}
        if destination == "settings", preferences.isDirty {pendingDestination=requested}
        else {destination=requested}
    })}
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var destination: String?="home"
    @State private var game: MobileGameRoute?
    @State private var document: SettingsDocument?
    var body: some View {
        Group {
            if shell.canPlay {productNavigation}
            else {NavigationStack {legalContent.toolbar {languageToolbar}}}
        }
            .alert(shell.language.text("error"), isPresented: Binding(get: { shell.error != nil || preferences.error != nil }, set: { if !$0 { shell.error = nil; preferences.error = nil } })) {
                Button(shell.language.text("ok")) { shell.error = nil; preferences.error = nil }
            } message: { Text(preferences.error ?? shell.error ?? "") }
            .sheet(item: $document) { item in
                NavigationStack {
                    ScrollView { Text(item.contents(language: shell.language) ?? shell.language.text("documentUnavailable")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle(shell.language.text(item.titleKey))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(shell.language.text("ok")) { document = nil }.frame(minHeight: 44) } }
                }
            }
            .fullScreenCover(item: $game) { route in MobileGameView(route: route, language: shell.language, settings: preferences.settings) { game = nil } }
        .environment(\.locale, shell.language.locale)
        .environment(\.shellPalette,palette)
        .environment(\.defaultMinListRowHeight,44 + 2 * preferences.settings.verticalPadding)
        .preferredColorScheme(palette.dark ? .dark : .light)
        .tint(palette.accentText.color)
        .background(palette.background.color)
        .onChange(of:preferences.settings) {_, settings in shell.language=settings.host.language}
        .confirmationDialog(shell.language.text("unsavedTitle"),isPresented:Binding(get:{pendingDestination != nil},set:{if !$0 {pendingDestination=nil}})) {
            Button(shell.language.text("saveLeave")) {if preferences.save() {destination=pendingDestination}; pendingDestination=nil}
            Button(shell.language.text("discardLeave"),role:.destructive) {preferences.discard(); destination=pendingDestination; pendingDestination=nil}
            Button(shell.language.text("cancel"),role:.cancel) {pendingDestination=nil}
        } message: {Text(shell.language.text("unsavedBody"))}
        .onChange(of: shell.canPlay) { _, allowed in if allowed {library.reload()} }
        .onAppear {
            #if DEBUG
            if LegalAgreement.bypassRequested(), ProcessInfo.processInfo.arguments.contains("--ios-settings-preview") {
                if let option=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--ios-preview-theme=")}),
                   let theme=ShellTheme(rawValue:String(option.dropFirst("--ios-preview-theme=".count))) {
                    preferences.draft.host.theme=theme.rawValue; preferences.save()
                }
                if ProcessInfo.processInfo.arguments.contains("--ios-preview-landscape") {preferences.draft.landscapeLocked=true; preferences.save()}
                destination="settings"
            }
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
                        Picker(shell.language.text("language"), selection: Binding(get:{shell.language},set:{preferences.quickLanguage($0)})) {
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
                    List(selection:selection) {
                        Label(shell.language.text("dashboard"),systemImage:"house").tag("home")
                        Label(shell.language.text("library"),systemImage:"books.vertical").tag("library")
                        Label(shell.language.text("settings"),systemImage:"gearshape").tag("settings")
                    }.navigationTitle("Aether")
                } detail: {NavigationStack {if destination=="library" {libraryPage} else if destination=="settings" {settingsPage} else {home.toolbar {languageToolbar}}}}
            } else {
                TabView(selection:selection) {
                    NavigationStack {home.toolbar {languageToolbar}}.tabItem {Label(shell.language.text("dashboard"),systemImage:"house")}.tag("home")
                    NavigationStack {libraryPage}.tabItem {Label(shell.language.text("library"),systemImage:"books.vertical")}.tag("library")
                    NavigationStack {settingsPage}.tabItem {Label(shell.language.text("settings"),systemImage:"gearshape")}.tag("settings")
                }
            }
        }
    }
    private var settingsPage: some View {MobileSettingsView(preferences:preferences,language:shell.language)}
    private var libraryPage: some View {
        MobileLibraryView(model:library,shell:shell,preferences:preferences) { item in
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
                    }.disabled(library.isImporting || library.isEditingCover).buttonStyle(.borderedProminent).tint(palette.controlAccent.color).frame(minHeight: 44)
                }.padding(.vertical, 8)
            }.listRowBackground(palette.surface.color)
            Section(shell.language.text("aboutSection")) {
                ForEach([SettingsDocument.privacy, .statement, .license, .additionalLicense, .thirdParty]) { item in
                    Button(shell.language.text(item.titleKey)) { document = item }.frame(minHeight: 44)
                }
            }.listRowBackground(palette.surface.color)
        }.listRowBackground(palette.surface.color).scrollContentBackground(.hidden).background(palette.background.color).navigationTitle(shell.language.text("dashboard"))
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
            .buttonStyle(.borderedProminent).tint(palette.controlAccent.color).frame(minHeight: 44).disabled(!readable)
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
    @Published var orientationFailed = false
    private let orientation: MobileOrientationOwner
    @Published private(set) var controlsVisible: Bool
    @Published private(set) var controlMode: VirtualControlMode
    @Published private(set) var controlHeld = false
    let controlOpacity: Double
    let controlEntryAllowed: Bool
    private var keyState=KeyInputState()
    private var inputEpoch=UUID()
    private var cursorDragOwner: (id: UUID, epoch: UUID)?
    init(url: URL, settings: HostSettings, landscapeLocked: Bool = false) {
        controlsVisible=settings.virtualControls
        controlMode=VirtualControlMode.normalized(settings.virtualControlMode) ?? .touch
        controlOpacity=VirtualControlOpacity.normalized(settings.virtualControlKeyboardOpacity)
        controlEntryAllowed=settings.virtualControlMenuEnabled
        orientation = MobileOrientationOwner(locked:landscapeLocked)
        controller = AetherMobileGameController(gameURL: url)
        controller.gameCanvasLabel=settings.language.text("mobileGameImage")
        controller.gameCanvasHint=settings.language.text("mobileGameImageHint")
        controller.virtualMouseMode=controlsVisible && controlMode == .mouse
        controller.prefersSoftwareRendering = settings.renderer == "software"
        controller.engineOptions = Dictionary(uniqueKeysWithValues:settings.engineOptions.filter {$0.key != "fps_limit"}.map {($0.key,$0.value)})
        controller.statusChanged = { [weak self] in self?.status = $0 }
        controller.failed = { [weak self] in self?.error = $0 }
        controller.presentationFallback = { [weak self] in self?.fallbackKey = $0 }
        orientation.failure = { [weak self] in self?.orientationFailed = true }
        controller.sceneReady = { [owner=orientation] in owner.begin(scene:$0) }
        controller.didClose = { [owner=orientation] in owner.end() }
        controller.inputWillReset = { [weak self] in self?.releaseInputs() }
    }
    func retryOrientation() {orientationFailed=false; orientation.retry()}
    func releaseInputs() {
        inputEpoch=UUID()
        for event in keyState.releaseAll() {_ = controller.sendHostKey(pressed:event.pressed,keyCode:event.key,modifiers:event.modifiers)}
        controller.hostInputModifiers=0
        if controlHeld {controlHeld=false}
    }
    func toggleControls() {
        controller.cancelHostInput(); controlsVisible.toggle()
        controller.virtualMouseMode=controlsVisible && controlMode == .mouse
    }
    func setControlMode(_ mode: VirtualControlMode) {
        guard mode != controlMode else {return}
        controller.cancelHostInput(); controlMode=mode
        controller.virtualMouseMode=controlsVisible && controlMode == .mouse
    }
    func tapKey(_ key: Int32) {
        guard controller.inputAvailable else {return}
        let modifiers: Int32=controlHeld ? 0x04 : 0
        for event in keyState.set(.virtual,key:key,pressed:true,modifiers:modifiers) {
            _ = controller.sendHostKey(pressed:event.pressed,keyCode:event.key,modifiers:event.modifiers)
        }
        for event in keyState.set(.virtual,key:key,pressed:false,modifiers:modifiers) {
            _ = controller.sendHostKey(pressed:event.pressed,keyCode:event.key,modifiers:event.modifiers)
        }
    }
    func setControlHeld(_ held: Bool) {
        guard !held || controller.inputAvailable else {return}
        let epoch=inputEpoch
        for event in keyState.set(.virtual,key:0x11,pressed:held,modifiers:held ? 0x04 : 0) {
            _ = controller.sendHostKey(pressed:event.pressed,keyCode:event.key,modifiers:event.modifiers)
        }
        guard inputEpoch == epoch else {return}
        controller.hostInputModifiers=held ? 0x04 : 0; controlHeld=held
    }
    func beginCursorDrag() -> UUID {
        let id=UUID(); cursorDragOwner=(id,inputEpoch); return id
    }
    func moveCursor(_ delta: CGSize, owner: UUID) {
        guard cursorDragOwner?.id == owner, cursorDragOwner?.epoch == inputEpoch else {return}
        nudgeCursor(delta)
    }
    func endCursorDrag(_ owner: UUID) {if cursorDragOwner?.id == owner {cursorDragOwner=nil}}
    func nudgeCursor(_ delta: CGSize) {controller.moveVirtualCursor(by:delta)}
    func clickCursor() {controller.clickVirtualCursor()}

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
    init(route: MobileGameRoute, language: ShellLanguage, settings: MobilePreferences, close: @escaping () -> Void) {
        _game = StateObject(wrappedValue: MobileGameViewModel(url: route.url, settings: settings.host, landscapeLocked: settings.landscapeLocked))
        self.language=language; self.close=close; self.title=route.title
    }
    @State private var showGameMenu=false
    private var controlsButton: some View {
        Button(language.text(game.controlsVisible ? "virtualControlsHide" : "virtualControlsShow")) {game.toggleControls()}
            .frame(minHeight:44).accessibilityIdentifier("mobile.controls.toggle")
    }
    private var backButton: some View {
        Button {confirmReturn=true} label: {Label(language.text("mobileReturnShell"),systemImage:"chevron.left")}
            .frame(minWidth:44,minHeight:44).accessibilityIdentifier("mobile.game.return")
    }
    private var menuButton: some View {
        Button {showGameMenu=true} label: {Label(language.text("mobileGameMenu"),systemImage:"ellipsis.circle").labelStyle(.iconOnly)}
            .frame(minWidth:44,minHeight:44).accessibilityIdentifier("mobile.game.menu")
    }
    var body: some View {
        GeometryReader {geometry in
            VStack(spacing:0) {
                ViewThatFits(in:.horizontal) {
                    HStack {backButton; Text(title).font(.headline).lineLimit(1); Spacer(); controlsButton; menuButton}
                    VStack {HStack {backButton; Text(title).font(.headline).lineLimit(1); Spacer(); menuButton}; controlsButton}
                }.buttonStyle(.bordered).padding(.horizontal)
                if let key=game.fallbackKey {Text(language.text(key)).font(.caption).padding(.horizontal)}
                if game.orientationFailed {
                    Text(language.text("mobileLandscapeFailed")).font(.caption).padding(.horizontal)
                    Button(language.text("mobileLandscapeRetry")) {game.retryOrientation()}.frame(minHeight:44)
                }
                MobileGameSurface(controller:game.controller)
                    .overlay(alignment:.topTrailing) {
                        if game.controlEntryAllowed && !game.controlsVisible {
                            Button {game.toggleControls()} label: {Label(language.text("virtualControlsShow"),systemImage:"keyboard").labelStyle(.iconOnly)}
                                .frame(minWidth:44,minHeight:44).buttonStyle(.borderedProminent).padding(8)
                                .accessibilityIdentifier("mobile.controls.entry")
                        }
                    }
                if game.controlsVisible {
                    MobileControlPad(game:game,language:language)
                        .frame(maxHeight:min(260,max(88,geometry.size.height*0.42)))
                }
                Text(game.status == "paused" ? language.text("mobilePaused") : game.status == "running" ? language.text("mobileRunning") : game.status == "restartRequired" ? language.text("mobileAudioRestart") : game.status)
                    .font(.caption).frame(minHeight:24).foregroundStyle(.secondary)
            }.background(Color.black).foregroundStyle(.white)
        }
        .confirmationDialog(language.text("mobileReturnShell"), isPresented: $confirmReturn) {
            Button(language.text("mobileCloseGame")) { game.controller.stop(); close() }.accessibilityIdentifier("mobile.game.confirmReturn")
            Button(language.text("continue"), role: .cancel) {}
        }
        .alert(language.text("error"), isPresented: Binding(get: { game.error != nil }, set: { if !$0 { game.error=nil } })) {
            Button(language.text("ok")) { game.controller.stop(); close() }
        } message: { Text(game.error ?? "") }
        .confirmationDialog(language.text("mobileGameMenu"),isPresented:$showGameMenu) {
            Button(language.text(game.controlsVisible ? "virtualControlsHide" : "virtualControlsShow")) {showGameMenu=false; game.controller.setSystemModalPresented(false); game.toggleControls()}
            Button(language.text("enterKey")) {showGameMenu=false; game.controller.setSystemModalPresented(false); game.tapKey(0x0D)}
            Button(language.text("mobileResumeAudio")) {showGameMenu=false; game.controller.setSystemModalPresented(false); game.controller.resumeAudio()}
            Button(language.text("mobileCloseGame")) {showGameMenu=false; confirmReturn=true}
            Button(language.text("cancel"),role:.cancel) {}
        }
        .onChange(of: confirmReturn || showGameMenu) {_, presented in game.controller.setSystemModalPresented(presented)}
        .onDisappear { game.controller.stop() }
    }
}
