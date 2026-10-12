import Foundation

/// First-use legal agreement: version gate, persistence, corrupt-file handling
/// and the debug-only bypass. Kept separate from the settings draft.
enum LegalAcceptanceTests {
    static func run(root: URL) throws {
        let url = root.appendingPathComponent("legal/acceptance.json")
        let store = LegalAcceptanceStore(url: url)
        // A fresh store is not satisfied.
        precondition(!store.isSatisfied())
        precondition(store.load() == nil)
        // A corrupt file must not be trusted; the gate re-shows.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        precondition(!store.isSatisfied(), "a corrupt acceptance file must not satisfy the gate")
        // Accepting persists the current version with a timestamp.
        precondition(store.accept(at: Date(timeIntervalSince1970: 1000)))
        precondition(store.load()?.version == LegalAgreement.version)
        precondition(store.load()?.acceptedAt == 1000)
        precondition(store.isSatisfied())
        // An outdated or future accepted version re-shows the gate.
        precondition(store.accept(version: "2020-01-01.1"))
        precondition(!store.isSatisfied(), "an outdated acceptance must re-show the gate")
        try FileManager.default.removeItem(at: url)
        precondition(!store.isSatisfied())
        // The bypass is explicit and debug-only.
        precondition(!LegalAgreement.bypassRequested(environment: [:]))
        precondition(!LegalAgreement.bypassRequested(environment: ["AETHER_HOST_BYPASS_LEGAL_GATE": "0"]))
        #if DEBUG
        precondition(LegalAgreement.bypassRequested(environment: ["AETHER_HOST_BYPASS_LEGAL_GATE": "1"]))
        #endif
        print("PASS: first-use legal agreement version gate, persistence, corrupt-file handling and debug bypass")
    }
}
