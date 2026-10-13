import Foundation
import Combine

@MainActor
final class MobileShellState: ObservableObject {
    @Published private(set) var requiredDocument: LegalDocument?
    @Published private(set) var declined = false
    @Published var language = ShellLanguage.system
    @Published var error: String?
    let legalStore: LegalAcceptanceStore
    let gamesRoot: URL
    let supportRoot: URL
    private let bypass: Bool

    init(supportRoot: URL? = nil, gamesRoot: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let fm = FileManager.default
        let support = supportRoot ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aether", isDirectory: true)
        self.supportRoot = support
        self.gamesRoot = gamesRoot ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Games", isDirectory: true)
        legalStore = LegalAcceptanceStore(url: support.appendingPathComponent("legal-acceptance.json"))
        bypass = LegalAgreement.bypassRequested(environment: environment)
        requiredDocument = bypass ? nil : legalStore.requiredDocument()
    }
    var canPlay: Bool { !declined && requiredDocument == nil }
    func decline() { declined = true }
    func reviewAgain() { declined = false; requiredDocument = legalStore.requiredDocument() }
    func acceptDocument() {
        guard let document = requiredDocument else { return }
        guard legalStore.accept(document) else { error = language.text("mobileLegalWriteFailed"); return }
        requiredDocument = legalStore.requiredDocument()
    }
    func prepareDemo(source: URL? = Bundle.main.url(forResource: "data", withExtension: "xp3")) throws -> URL {
        guard canPlay else { throw CocoaError(.userCancelled) }
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let directory = gamesRoot.appendingPathComponent("Demo", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let packed = directory.appendingPathComponent("data.xp3")
        if !fm.fileExists(atPath: packed.path) {
            let staging = directory.appendingPathComponent(UUID().uuidString + ".partial")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try fm.moveItem(at: staging, to: packed)
        }
        return directory
    }
}
