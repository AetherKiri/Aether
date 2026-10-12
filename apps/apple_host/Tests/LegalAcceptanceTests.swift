import Foundation

/// First-use legal documents: Godot's privacy agreement then the App Store
/// additional statement, each with its own version gate.
enum LegalAcceptanceTests {
    static func run(root: URL) throws {
        let url = root.appendingPathComponent("legal/acceptance.json")
        let store = LegalAcceptanceStore(url: url)
        // A fresh store needs the privacy agreement first, then the statement.
        precondition(store.requiredDocument() == .privacy)
        precondition(!store.isSatisfied(.privacy) && !store.isSatisfied(.statement))
        // A corrupt file must not be trusted; the gate re-shows.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        precondition(store.requiredDocument() == .privacy, "a corrupt acceptance file must not satisfy the gate")
        // Accepting the privacy agreement advances to the statement.
        precondition(store.accept(.privacy, at: Date(timeIntervalSince1970: 1000)))
        precondition(store.isSatisfied(.privacy) && !store.isSatisfied(.statement))
        precondition(store.load().privacy?.version == LegalAgreement.version)
        precondition(store.load().privacy?.acceptedAt == 1000)
        precondition(store.requiredDocument() == .statement)
        // Accepting the statement satisfies both, in either order.
        precondition(store.accept(.statement, at: Date(timeIntervalSince1970: 2000)))
        precondition(store.requiredDocument() == nil)
        // An outdated acceptance re-shows that document.
        var record = store.load()
        record.privacy = .init(version: "2020-01-01.1", acceptedAt: 1)
        try JSONEncoder().encode(record).write(to: url)
        precondition(store.requiredDocument() == .privacy)
        // The v1 single-document file migrates to the privacy entry.
        let legacy: [String: Any] = ["version": LegalAgreement.version, "acceptedAt": 3000.0]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let migrated = store.load()
        precondition(migrated.privacy?.version == LegalAgreement.version && migrated.privacy?.acceptedAt == 3000)
        precondition(migrated.statement == nil)
        precondition(store.requiredDocument() == .statement)
        // The bypass is explicit and debug-only.
        precondition(!LegalAgreement.bypassRequested(environment: [:]))
        precondition(!LegalAgreement.bypassRequested(environment: ["AETHER_HOST_BYPASS_LEGAL_GATE": "0"]))
        #if DEBUG
        precondition(LegalAgreement.bypassRequested(environment: ["AETHER_HOST_BYPASS_LEGAL_GATE": "1"]))
        #endif
        print("PASS: first-use legal documents (privacy then statement), per-document version gate, legacy migration and debug bypass")
    }
}
