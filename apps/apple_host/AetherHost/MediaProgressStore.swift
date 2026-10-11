import Foundation

struct MediaProgressStore {
    struct Entry: Codable { let seconds: Double; let updated: Date; var duration: Double? = nil }
    let url: URL
    func entries() throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
    }
    func position(for file: URL, duration: Double) throws -> Double {
        let position = try entries()[file.standardizedFileURL.path]?.seconds ?? 0
        return position.isFinite && position > 0 && position < max(0, duration - 1) ? position : 0
    }
    func save(_ seconds: Double, for file: URL, duration: Double? = nil) throws {
        guard seconds.isFinite, seconds >= 0 else { return }
        var entries = try entries()
        entries[file.standardizedFileURL.path] = Entry(seconds: seconds, updated: Date(), duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        let limited = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.updated > $1.value.updated }.prefix(200).map { ($0.key, $0.value) })
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(limited).write(to: url, options: .atomic)
    }

    func remove(for file: URL) throws {
        var values = try entries()
        values.removeValue(forKey: file.standardizedFileURL.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
}
