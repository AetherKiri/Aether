import Foundation

/// First-use legal documents, mirrored from Godot's `LEGAL_AGREEMENT_VERSION`
/// and `IOS_STATEMENT_VERSION`. Godot requires both on Apple platforms: the
/// privacy agreement first, then the App Store additional statement.
enum LegalAgreement {
    static let version = "2026-07-27.4"
    /// Godot's `IOS_STATEMENT_VERSION`.
    static let statementVersion = "2026-08-04"
    static let bypassEnvironmentKey = "AETHER_HOST_BYPASS_LEGAL_GATE"

    /// Unattended test/benchmark launches may bypass the gate, but only in a
    /// debug build, mirroring Godot's `AETHERKIRI_BYPASS_LEGAL_GATE`.
    static func bypassRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        return environment[bypassEnvironmentKey] == "1"
        #else
        return false
        #endif
    }
}

/// The required first-use documents, in Godot's order.
enum LegalDocument: String, CaseIterable, Identifiable {
    case privacy, statement

    var id: String { rawValue }
    var version: String {
        self == .privacy ? LegalAgreement.version : LegalAgreement.statementVersion
    }
    var titleKey: String { self == .privacy ? "legalTitle" : "statementTitle" }
    var summaryKey: String { self == .privacy ? "legalFirstSummary" : "statementFirstSummary" }
    var settingsDocument: SettingsDocument { self == .privacy ? .privacy : .statement }
}

/// A small JSON record under the library root. Corrupt or missing files simply
/// mean "not accepted yet", which re-shows the gate rather than trusting state.
struct LegalAcceptanceStore {
    struct Entry: Codable, Equatable {
        var version: String
        var acceptedAt: Double
    }
    struct Record: Codable, Equatable {
        var privacy: Entry?
        var statement: Entry?
        func entry(_ document: LegalDocument) -> Entry? {
            document == .privacy ? privacy : statement
        }
    }
    /// The first version stored a single privacy acceptance as `{version, acceptedAt}`.
    private struct Legacy: Codable {
        var version: String
        var acceptedAt: Double
    }

    let url: URL

    func load() -> Record {
        guard let data = try? Data(contentsOf: url) else { return Record() }
        if let record = try? JSONDecoder().decode(Record.self, from: data),
           record.privacy != nil || record.statement != nil {
            return record
        }
        if let legacy = try? JSONDecoder().decode(Legacy.self, from: data) {
            return Record(privacy: Entry(version: legacy.version, acceptedAt: legacy.acceptedAt), statement: nil)
        }
        return Record()
    }

    func isSatisfied(_ document: LegalDocument) -> Bool {
        load().entry(document)?.version == document.version
    }

    /// The first document that still needs acceptance, in Godot's order.
    func requiredDocument() -> LegalDocument? {
        LegalDocument.allCases.first { !isSatisfied($0) }
    }

    @discardableResult
    func accept(_ document: LegalDocument, at date: Date = Date()) -> Bool {
        var record = load()
        let entry = Entry(version: document.version, acceptedAt: date.timeIntervalSince1970)
        if document == .privacy { record.privacy = entry } else { record.statement = entry }
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
