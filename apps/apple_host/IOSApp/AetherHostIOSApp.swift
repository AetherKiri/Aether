import SwiftUI

@main
struct AetherHostIOSApp: App {
    @StateObject private var shell = MobileShellState()
    var body: some Scene {
        WindowGroup { MobileRootView(shell: shell) }
    }
}

struct MobileRootView: View {
    @ObservedObject var shell: MobileShellState
    @State private var game: MobileGameRoute?
    @State private var document: SettingsDocument?
    var body: some View {
        NavigationStack {
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
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Aether Demo", systemImage: "book.pages").font(.title2)
                                Text(shell.language.text("builtinDemo")).foregroundStyle(.secondary)
                                Button(shell.language.text("play")) {
                                    do { game = MobileGameRoute(url: try shell.prepareDemo()) }
                                    catch { shell.error = error.localizedDescription }
                                }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                            }.padding(.vertical, 8)
                        }
                        Section(shell.language.text("aboutSection")) {
                            ForEach([SettingsDocument.privacy, .statement, .license, .additionalLicense, .thirdParty]) { item in
                                Button(shell.language.text(item.titleKey)) { document = item }.frame(minHeight: 44)
                            }
                        }
                    }.navigationTitle(shell.language.text("dashboard"))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(shell.language.text("language"), selection: $shell.language) {
                            ForEach(ShellLanguage.allCases) { language in Text(language.name).tag(language) }
                        }
                    } label: { Label(shell.language.text("language"), systemImage: "globe").frame(minWidth: 44, minHeight: 44) }
                }
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
        }.environment(\.locale, shell.language.locale)
        .onAppear {
            #if DEBUG
            if LegalAgreement.bypassRequested(), ProcessInfo.processInfo.arguments.contains("--ios-demo-smoke"), game == nil {
                do { game = MobileGameRoute(url: try shell.prepareDemo()) }
                catch { shell.error = error.localizedDescription }
            }
            #endif
        }
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
}
@MainActor
final class MobileGameViewModel: ObservableObject {
    let controller: AetherMobileGameController
    @Published var status = ""
    @Published var error: String?
    init(url: URL) {
        controller = AetherMobileGameController(gameURL: url)
        controller.statusChanged = { [weak self] in self?.status = $0 }
        controller.failed = { [weak self] in self?.error = $0 }
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
    @State private var confirmReturn = false
    init(route: MobileGameRoute, language: ShellLanguage, close: @escaping () -> Void) {
        _game = StateObject(wrappedValue: MobileGameViewModel(url: route.url))
        self.language=language; self.close=close
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    Button { confirmReturn = true } label: { Label(language.text("mobileBackHome"), systemImage: "chevron.left") }.frame(minWidth: 44, minHeight: 44)
                    Text("Aether Demo").font(.headline)
                    Button(language.text("enterKey")) { game.controller.sendEnter() }.frame(minWidth: 44, minHeight: 44)
                    Button(language.text("mobileResumeAudio")) { game.controller.resumeAudio() }.frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.bordered).padding(.horizontal).frame(minHeight: 52)
            }
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
