import Foundation

/// First-use legal agreement, mirrored from Godot's `LEGAL_AGREEMENT_VERSION`.
/// Acceptance is stored separately from the editable settings draft so it
/// cannot be revoked by discarding a settings change.
enum LegalAgreement {
    static let version = "2026-07-27.4"
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

struct LegalAcceptance: Codable, Equatable {
    var version: String
    var acceptedAt: Double
}

/// A small JSON record under the library root. Corrupt or missing files simply
/// mean "not accepted yet", which re-shows the gate rather than trusting state.
struct LegalAcceptanceStore {
    let url: URL

    func load() -> LegalAcceptance? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LegalAcceptance.self, from: data)
    }

    func isSatisfied() -> Bool {
        load()?.version == LegalAgreement.version
    }

    @discardableResult
    func accept(version: String = LegalAgreement.version, at date: Date = Date()) -> Bool {
        let record = LegalAcceptance(version: version, acceptedAt: date.timeIntervalSince1970)
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
