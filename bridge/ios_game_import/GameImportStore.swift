import Foundation

/// Shared import metadata and bounded copying for in-place and temporary provider URLs.
enum GameImportStore {
    typealias Progress = (_ bytes: Int64) -> Void
    static let fileManager = FileManager.default
    static let metadataName = "import.json"

    struct Job: Codable {
        var name: String
        var destination: String?
        var sourceBookmark: Data?
        var temporaryFile: Bool?
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
        guard source.isFileURL else { throw failure("Select a local game folder or file.") }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              values.isDirectory == true || values.isRegularFile == true else {
            throw failure(NSLocalizedString("import.unsupported", value: "Select a game folder or an archive file.", comment: ""))
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
                    try autoreleasepool { try copy(child, target.appendingPathComponent(child.lastPathComponent), depth: depth + 1) }
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
                    // Foundation may autorelease each NSData returned by a read.
                    // Drain every chunk, not at the end of a multi-GB import.
                    let count = try autoreleasepool { () throws -> Int in
                        let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                        if !data.isEmpty { try output.write(contentsOf: data) }
                        return data.count
                    }
                    if count == 0 { break }
                    bytes += Int64(count)
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

    /// The extension retains an in-place provider URL, not a second game copy.
    /// The host resolves this bookmark and performs the one copy into Games.
    static func receive(_ source: URL, suggestedName: String? = nil, into incoming: URL,
                        cancelled: () -> Bool = { false }, progress: Progress = { _ in }) throws -> URL {
        guard !isInside(incoming, source), !cancelled() else { throw CocoaError(.userCancelled) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = try sourceName(source, suggestedName: suggestedName)
        let bookmark = try source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let job = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: job, withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(Job(name: name, sourceBookmark: bookmark))
                .write(to: job.appendingPathComponent(metadataName), options: .atomic)
            return job
        } catch { try? fileManager.removeItem(at: job); throw error }
    }

    // Temporary provider URLs expire as soon as the provider callback returns.
    // Copy only those files into the app group before acknowledging the share.
    static func receiveTemporaryFile(_ source: URL, suggestedName: String?, into incoming: URL,
                                     cancelled: () -> Bool, progress: Progress) throws -> URL {
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw failure(NSLocalizedString("import.unsupported", value: "Select a game folder or an archive file.", comment: ""))
        }
        let name = try sourceName(source, suggestedName: suggestedName)
        let id = UUID().uuidString
        let job = incoming.appendingPathComponent("Receiving-" + id, isDirectory: true)
        let ready = incoming.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: job, withIntermediateDirectories: true)
        do {
            try copyTree(source, to: job.appendingPathComponent("payload"), cancelled: cancelled, progress: progress)
            try JSONEncoder().encode(Job(name: name, temporaryFile: true)).write(to: job.appendingPathComponent(metadataName), options: .atomic)
            try fileManager.moveItem(at: job, to: ready)
            return ready
        } catch { try? fileManager.removeItem(at: job); throw error }
    }

    static let workPrefix = "Importing-"
    static let workMarker = "aether-import-in-progress.json"

    static func importDirect(_ source: URL, suggestedName: String? = nil, into games: URL,
                             cancelled: () -> Bool = { false }, progress: Progress = { _ in }) throws -> URL {
        guard !isInside(games, source) else { throw failure("A folder cannot be imported into itself.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = try sourceName(source, suggestedName: suggestedName)
        try fileManager.createDirectory(at: games, withIntermediateDirectories: true)
        let work = games.appendingPathComponent(workPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: false)
        do {
            try JSONEncoder().encode(Job(name: name)).write(to: work.appendingPathComponent(workMarker))
            var copyError: Error?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                do { try copyTree(readable, to: work.appendingPathComponent("payload"), cancelled: cancelled, progress: progress) }
                catch { copyError = error }
            }
            if let error = copyError ?? coordinationError { throw error }
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            var number = 1
            while true {
                let destination = games.appendingPathComponent(uniqueName(name, in: games, number: number, isFile: try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true))
                if fileManager.fileExists(atPath: destination.path) { number += 1; continue }
                do {
                    // Same parent filesystem: publish by rename, without copying.
                    try fileManager.moveItem(at: work.appendingPathComponent("payload"), to: destination)
                    try fileManager.removeItem(at: work)
                    return destination
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    number += 1
                }
            }
        } catch { try? fileManager.removeItem(at: work); throw error }
    }

    /// Called once before accepting imports. Only remove our interrupted work;
    /// neither finished games nor user-created directories match this contract.
    static func cleanInterrupted(in games: URL) throws {
        guard fileManager.fileExists(atPath: games.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: games, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard item.lastPathComponent.hasPrefix(workPrefix),
                  UUID(uuidString: String(item.lastPathComponent.dropFirst(workPrefix.count))) != nil,
                  (try item.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  fileManager.fileExists(atPath: item.appendingPathComponent(workMarker).path) else { continue }
            try fileManager.removeItem(at: item)
        }
    }

    static func cleanLegacyPartials(in incoming: URL) throws {
        guard fileManager.fileExists(atPath: incoming.path) else { return }
        for entry in try fileManager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) {
            if entry.lastPathComponent.hasPrefix("Receiving-"),
               UUID(uuidString: String(entry.lastPathComponent.dropFirst("Receiving-".count))) != nil {
                let payload = entry.appendingPathComponent("payload")
                let date = try? (fileManager.fileExists(atPath: payload.path) ? payload : entry)
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let date, date.timeIntervalSinceNow < -86400 { try fileManager.removeItem(at: entry) }
            }
            if entry.lastPathComponent.hasPrefix(".partial-"), UUID(uuidString: String(entry.lastPathComponent.dropFirst(9))) != nil {
                try fileManager.removeItem(at: entry)
            }
        }
    }

    static func revealLegacyWork(in games: URL) throws {
        guard fileManager.fileExists(atPath: games.path) else { return }
        let prefix = ".aether-import-"
        for item in try fileManager.contentsOfDirectory(at: games, includingPropertiesForKeys: nil) {
            guard item.lastPathComponent.hasPrefix(prefix),
                  let id = UUID(uuidString: String(item.lastPathComponent.dropFirst(prefix.count))) else { continue }
            var target = games.appendingPathComponent("Recovered Import-" + id.uuidString)
            if fileManager.fileExists(atPath: target.path) { target = games.appendingPathComponent("Recovered Import-" + UUID().uuidString) }
            try fileManager.moveItem(at: item, to: target)
        }
    }

    static func pending(in incoming: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: incoming.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && fileManager.fileExists(atPath: $0.appendingPathComponent(metadataName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func uniqueName(_ name: String, in games: URL, number: Int = 1, isFile: Bool = false) -> String {
        if number == 1 { return name }
        let url = URL(fileURLWithPath: name)
        if (isFile || name.lowercased().hasSuffix(".xp3")) && !url.pathExtension.isEmpty {
            return "\(url.deletingPathExtension().lastPathComponent) (\(number)).\(url.pathExtension)"
        }
        return "\(name) (\(number))"
    }

    /// Also consumes jobs left by older versions. Never create hidden staging
    /// directories or retain completed payloads in the shared container.
    static func promote(_ jobURL: URL, into games: URL, cancelled: () -> Bool = { false }, progress: Progress = { _ in }) throws -> URL {
        guard UUID(uuidString: jobURL.lastPathComponent) != nil else { throw failure("Invalid import job.") }
        let metadata = jobURL.appendingPathComponent(metadataName)
        var job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: metadata))
        guard validName(job.name), job.destination.map(validName) ?? true else { throw failure("Invalid import name.") }
        if let bookmark = job.sourceBookmark {
            var stale = false
            let source = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            let destination = try importDirect(source, suggestedName: job.name, into: games, cancelled: cancelled, progress: progress)
            try fileManager.removeItem(at: jobURL)
            return destination
        }
        let payload = jobURL.appendingPathComponent("payload")
        if job.temporaryFile == true, fileManager.fileExists(atPath: payload.path) {
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            try fileManager.createDirectory(at: games, withIntermediateDirectories: true)
            var number = 1
            while true {
                let name = uniqueName(job.name, in: games, number: number, isFile: true)
                let destination = games.appendingPathComponent(name)
                job.destination = name
                try JSONEncoder().encode(job).write(to: metadata, options: .atomic)
                do {
                    try fileManager.moveItem(at: payload, to: destination)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    number += 1
                    continue
                }
                try fileManager.removeItem(at: jobURL)
                return destination
            }
        }
        let oldWork = games.appendingPathComponent(".aether-import-" + jobURL.lastPathComponent)
        if fileManager.fileExists(atPath: payload.path) {
            if fileManager.fileExists(atPath: oldWork.path) { try fileManager.removeItem(at: oldWork) }
            let destination = try importDirect(payload, suggestedName: job.name, into: games, cancelled: cancelled, progress: progress)
            try fileManager.removeItem(at: jobURL)
            return destination
        }
        if fileManager.fileExists(atPath: oldWork.path) {
            var number = 1
            while fileManager.fileExists(atPath: games.appendingPathComponent(uniqueName(job.name, in: games, number: number)).path) { number += 1 }
            let destination = games.appendingPathComponent(uniqueName(job.name, in: games, number: number))
            try fileManager.moveItem(at: oldWork, to: destination)
            try fileManager.removeItem(at: jobURL)
            return destination
        }
        if let name = job.destination, fileManager.fileExists(atPath: games.appendingPathComponent(name).path) {
            try fileManager.removeItem(at: jobURL)
            return games.appendingPathComponent(name)
        }
        throw failure("The imported folder is missing. Share it again from Files.")
    }
}
