import Foundation

/// Shared by the application and its Action extension. Completed jobs are
/// published by rename; the app never sees a half-copied game as importable.
enum GameImportStore {
    typealias Progress = (_ bytes: Int64) -> Void
    static let fileManager = FileManager.default
    static let metadataName = "import.json"

    struct Job: Codable {
        var name: String
        var destination: String?
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "AetherGameImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func sharedRoot() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AetherImportAppGroup") as? String,
              !group.isEmpty,
              let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw failure(NSLocalizedString("import.group_unavailable", value: "The shared import folder is unavailable. Install an Aether build with the game-import capability enabled.", comment: ""))
        }
        let incoming = root.appendingPathComponent("Incoming", isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        return incoming
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") &&
            !name.contains("\\") && !name.contains("\0") && name.utf8.count <= 240
    }

    static func isInside(_ item: URL, _ directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = item.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    static func sourceName(_ source: URL, suggestedName: String?) throws -> String {
        guard source.isFileURL else { throw failure("Only local game folders and XP3 archives can be imported.") }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              values.isDirectory == true || source.pathExtension.lowercased() == "xp3" else {
            throw failure(NSLocalizedString("import.unsupported", value: "Select a complete game folder or an XP3 archive.", comment: ""))
        }
        let name = suggestedName.flatMap { validName($0) ? $0 : nil } ?? source.lastPathComponent
        guard validName(name) else { throw failure("The game folder name is invalid.") }
        return name
    }

    /// Copy in bounded chunks, including hidden files, and reject links rather
    /// than importing paths that could escape the selected game directory.
    static func copyTree(_ source: URL, to destination: URL,
                         cancelled: () -> Bool, progress: Progress) throws {
        var bytes: Int64 = 0
        var lastReport = Date.distantPast
        func copy(_ source: URL, _ target: URL, depth: Int) throws {
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            guard depth <= 128 else { throw failure("The game directory is nested too deeply.") }
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw failure("Symbolic links cannot be imported: \(source.lastPathComponent)") }
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try copy(child, target.appendingPathComponent(child.lastPathComponent), depth: depth + 1)
                }
            } else {
                guard values.isRegularFile == true else { throw failure("The folder contains an unsupported file: \(source.lastPathComponent)") }
                guard fileManager.createFile(atPath: target.path, contents: nil) else {
                    throw failure("Unable to create \(target.lastPathComponent). Check available storage.")
                }
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                while true {
                    guard !cancelled() else { throw CocoaError(.userCancelled) }
                    let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                    bytes += Int64(data.count)
                    if Date().timeIntervalSince(lastReport) >= 0.1 {
                        progress(bytes)
                        lastReport = Date()
                    }
                }
            }
        }
        do {
            try copy(source, destination, depth: 0)
            progress(bytes)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    static func receive(_ source: URL, suggestedName: String? = nil, into incoming: URL,
                        cancelled: () -> Bool = { false }, progress: Progress = { _ in }) throws -> URL {
        // Reject a source that contains our destination, before creating it.
        guard !isInside(incoming, source) else { throw failure("A folder cannot be imported into itself.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID().uuidString
        let staging = incoming.appendingPathComponent(".partial-" + id, isDirectory: true)
        let ready = incoming.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var result: Result<Void, Error> = .failure(failure("The file provider did not return a readable folder."))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result {
                let name = try sourceName(readable, suggestedName: suggestedName ?? source.lastPathComponent)
                try copyTree(readable, to: staging.appendingPathComponent("payload"),
                             cancelled: cancelled, progress: progress)
                try JSONEncoder().encode(Job(name: name)).write(to: staging.appendingPathComponent(metadataName), options: .atomic)
            }
        }
        do {
            if let error = coordinationError { throw error }
            try result.get()
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            try fileManager.moveItem(at: staging, to: ready)
            return ready
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    static func pending(in incoming: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: incoming.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func uniqueName(_ name: String, in games: URL, number: Int = 1) -> String {
        if number == 1 { return name }
        let url = URL(fileURLWithPath: name)
        if name.lowercased().hasSuffix(".xp3") {
            return "\(url.deletingPathExtension().lastPathComponent) (\(number)).\(url.pathExtension)"
        }
        return "\(name) (\(number))"
    }

    /// Keep a small journal until promotion finishes so a killed app can resume
    /// the move without exposing a partial folder or duplicating a completed one.
    static func promote(_ jobURL: URL, into games: URL) throws -> URL {
        guard UUID(uuidString: jobURL.lastPathComponent) != nil else { throw failure("Invalid import job.") }
        let metadata = jobURL.appendingPathComponent(metadataName)
        var job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: metadata))
        guard validName(job.name), job.destination.map(validName) ?? true else { throw failure("Invalid import name.") }
        try fileManager.createDirectory(at: games, withIntermediateDirectories: true)
        let payload = jobURL.appendingPathComponent("payload")
        let staging = games.appendingPathComponent(".aether-import-" + jobURL.lastPathComponent)
        if !fileManager.fileExists(atPath: payload.path), !fileManager.fileExists(atPath: staging.path),
           let name = job.destination, fileManager.fileExists(atPath: games.appendingPathComponent(name).path) {
            try fileManager.removeItem(at: jobURL)
            return games.appendingPathComponent(name)
        }
        if fileManager.fileExists(atPath: payload.path) {
            // A failed cross-container copy leaves its original intact.
            if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
            try fileManager.moveItem(at: payload, to: staging)
        }
        guard fileManager.fileExists(atPath: staging.path) else { throw failure("The imported folder is missing.") }
        var number = 1
        while true {
            let name = uniqueName(job.name, in: games, number: number)
            let destination = games.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) { number += 1; continue }
            job.destination = name
            try JSONEncoder().encode(job).write(to: metadata, options: .atomic)
            do {
                try fileManager.moveItem(at: staging, to: destination)
                try fileManager.removeItem(at: jobURL)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                number += 1 // Files.app or another importer won this name.
            }
        }
    }
}
