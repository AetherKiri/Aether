import Foundation

/// Filesystem part of automatic save sync; independently testable without an
/// iCloud account. All work directories are visible and bounded to one game.
enum AetherSaveSyncStore {
    static let fm = FileManager.default
    struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }
    typealias Snapshot = [String: Stamp]

    static func failure(_ message: String) -> NSError {
        NSError(domain: "AetherSaveSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func snapshot(_ root: URL) throws -> Snapshot {
        guard fm.fileExists(atPath: root.path) else { throw failure("The save directory is unavailable.") }
        var result: Snapshot = [:]
        func walk(_ folder: URL, _ prefix: String, _ depth: Int) throws {
            guard depth < 64 else { throw failure("Save directory nesting is too deep.") }
            let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else { throw failure("Invalid save directory.") }
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) {
                try autoreleasepool {
                    let value = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard value.isSymbolicLink != true else { throw failure("Linked save files are not supported.") }
                    let path = prefix + file.lastPathComponent
                    if value.isDirectory == true { try walk(file, path + "/", depth + 1) }
                    else {
                        guard value.isRegularFile == true, let size = value.fileSize, let date = value.contentModificationDate,
                              result.count < 100_000 else { throw failure("Invalid save file.") }
                        result[path] = Stamp(size: size, modified: date)
                    }
                }
            }
        }
        try walk(root, "", 0)
        return result
    }

    static func copyFile(_ source: URL, to target: URL) throws {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: target.path, contents: nil) else { throw failure("Cannot create save file.") }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while try autoreleasepool(invoking: { () throws -> Bool in
            let bytes = try input.read(upToCount: 256 * 1024) ?? Data()
            if bytes.isEmpty { return false }
            try output.write(contentsOf: bytes)
            return true
        }) { }
        try output.synchronize()
        guard let date = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { throw failure("The save file changed while copying.") }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
    }

    static func stage(_ source: URL, in parent: URL, files: Snapshot, expected: Snapshot? = nil) throws -> URL {
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try cleanWork(in: parent, prefix: "Save Sync Incoming-")
        let staging = parent.appendingPathComponent("Save Sync Incoming-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for name in files.keys.sorted() { try autoreleasepool { try copyFile(source.appendingPathComponent(name), to: staging.appendingPathComponent(name)) } }
            guard try snapshot(source) == (expected ?? files) else { throw failure("Saves changed during synchronization; retrying on the next check.") }
            return staging
        } catch { try? fm.removeItem(at: staging); throw error }
    }

    /// Complete the download before replacing the local bank. A visible backup
    /// only lives across the final rename and is removed immediately on success.
    static func replaceLocal(from remote: URL, to local: URL) throws {
        try recoverLocal(local)
        let files = try snapshot(remote)
        let stage = try stage(remote, in: local.deletingLastPathComponent(), files: files)
        defer { try? fm.removeItem(at: stage) }
        let previous = local.deletingLastPathComponent().appendingPathComponent("Save Sync Previous")
        let existed = fm.fileExists(atPath: local.path)
        if existed { try fm.moveItem(at: local, to: previous) }
        do { try fm.moveItem(at: stage, to: local) }
        catch {
            if existed { try fm.moveItem(at: previous, to: local) }
            throw error
        }
        if existed { try fm.removeItem(at: previous) }
    }

    static func recoverLocal(_ local: URL) throws {
        let previous = local.deletingLastPathComponent().appendingPathComponent("Save Sync Previous")
        if fm.fileExists(atPath: previous.path) {
            _ = try snapshot(previous) // never restore a link
            if !fm.fileExists(atPath: local.path) { try fm.moveItem(at: previous, to: local) }
            else { _ = try snapshot(local); try fm.removeItem(at: previous) }
        }
    }

    /// Only recognize our exact UUID work names, never arbitrary user saves.
    static func cleanWork(in folder: URL, prefix: String, recursive: Bool = false, depth: Int = 0) throws {
        guard depth < 64 else { throw failure("Save directory nesting is too deep.") }
        guard fm.fileExists(atPath: folder.path) else { return }
        for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw failure("Linked save files are not supported.") }
            if item.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(item.lastPathComponent.dropFirst(prefix.count))) != nil {
                try fm.removeItem(at: item)
            } else if recursive && values.isDirectory == true {
                try cleanWork(in: item, prefix: prefix, recursive: true, depth: depth + 1)
            }
        }
    }

    /// Only changed files are handed to iCloud. Unchanged saves are neither
    /// rewritten nor reuploaded; removed local files are removed remotely.
    static func upload(from local: URL, to remote: URL, previous: Snapshot?) throws -> Snapshot {
        let files = try snapshot(local)
        let changed = files.filter { previous?[$0.key] != $0.value }
        let staging = try stage(local, in: local.deletingLastPathComponent(), files: changed, expected: files)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try cleanWork(in: remote, prefix: "Save Sync File-", recursive: true)
        let existing = try snapshot(remote) // rejects links before writing through them
        for name in changed.keys.sorted() {
            let destination = remote.appendingPathComponent(name)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent("Save Sync File-" + UUID().uuidString)
            do {
                try copyFile(staging.appendingPathComponent(name), to: temporary)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: temporary)
                } else { try fm.moveItem(at: temporary, to: destination) }
            } catch { try? fm.removeItem(at: temporary); throw error }
        }
        for name in existing.keys where files[name] == nil { try fm.removeItem(at: remote.appendingPathComponent(name)) }
        return files
    }
}
