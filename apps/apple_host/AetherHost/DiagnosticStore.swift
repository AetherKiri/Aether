import Foundation

// Bounded local evidence; reports include only known logs, never game assets or saves.
final class DiagnosticStore {
    let root: URL
    let limit: Int
    private(set) var metadata: [String: String]
    private let formatter = ISO8601DateFormatter()
    private var logURL: URL { root.appendingPathComponent("host.log") }
    private var previousURL: URL { root.appendingPathComponent("host.previous.log") }
    private var metadataURL: URL { root.appendingPathComponent("session.json") }

    init(root: URL, limit: Int = 1_048_576) {
        self.root = root
        self.limit = max(1024, limit)
        metadata = (try? Data(contentsOf: root.appendingPathComponent("session.json")))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func update(_ values: [String: String], newSession: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if newSession {
            metadata = ["session": UUID().uuidString, "started": formatter.string(from: Date())]
        }
        metadata.merge(values) { _, new in new }
        metadata["updated"] = formatter.string(from: Date())
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    func append(_ message: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data((formatter.string(from: Date()) + " " + message + "\n").utf8).suffix(limit)
        let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > limit {
            if fm.fileExists(atPath: previousURL.path) { try fm.removeItem(at: previousURL) }
            if fm.fileExists(atPath: logURL.path) { try fm.moveItem(at: logURL, to: previousURL) }
        }
        if !fm.fileExists(atPath: logURL.path) { try Data().write(to: logURL) }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func tail(_ url: URL) -> String {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return "[not a regular log file]" }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let start = size > UInt64(limit) ? size - UInt64(limit) : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: limit) ?? Data()
            return "[modified: \(values.contentModificationDate.map { formatter.string(from: $0) } ?? "unknown"); tail: \(data.count)/\(size) bytes]\n"
                + String(decoding: data, as: UTF8.self)
        } catch { return "[unavailable: \(error.localizedDescription)]" }
    }

    func export(to destination: URL, context: [String: String]) throws {
        var report = "Aether Apple Host Diagnostics v1\nExported: \(formatter.string(from: Date()))\n"
        report += "Logs are bounded tails and may include earlier sessions. Missing logs are marked below.\n"
        for (key, value) in context.sorted(by: { $0.key < $1.key }) { report += "\(key): \(value)\n" }
        report += "\n=== Last session ===\n"
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) { report += "\(key): \(value)\n" }
        for url in [previousURL, logURL] {
            report += "\n=== \(url.lastPathComponent) ===\n" + tail(url) + "\n"
        }
        if let path = metadata["gamePath"] {
            for name in ["krkr2.log", "aetherkiri-engine.log"] {
                let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
                report += "\n=== \(name) (last game directory) ===\n" + tail(url) + "\n"
            }
        }
        // Protect our retained evidence if the save panel targets the log directory.
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        var retained = [logURL, previousURL, metadataURL]
        if let path = metadata["gamePath"] {
            retained += ["krkr2.log", "aetherkiri-engine.log"].map {
                URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent($0)
            }
        }
        guard !retained.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL == resolved
        }) else { throw CocoaError(.fileWriteInvalidFileName) }
        try Data(report.utf8).write(to: destination, options: .atomic)
    }
}
