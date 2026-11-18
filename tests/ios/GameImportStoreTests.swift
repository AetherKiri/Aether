import Foundation

@main struct GameImportStoreTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AetherImportTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source/天津罪")
        let incoming = root.appendingPathComponent("shared/Incoming")
        let games = root.appendingPathComponent("Documents/Games")
        try fm.createDirectory(at: source.appendingPathComponent("savedata"), withIntermediateDirectories: true)
        let files = ["savedata/slot01.sav": Data([0, 1, 2, 255]), ".patch": Data("补丁".utf8), "data.xp3": Data(repeating: 42, count: 2_500_000)]
        for (path, bytes) in files { try bytes.write(to: source.appendingPathComponent(path)) }
        // An extension only queues a bookmark. No hidden directory or game copy.
        let job = try GameImportStore.receive(source, into: incoming)
        try check(fm.contentsOfDirectory(atPath: job.path) == [GameImportStore.metadataName])
        var copied: Int64 = 0
        let destination = try GameImportStore.promote(job, into: games, progress: { copied = $0 })
        check(copied == files.values.reduce(0) { $0 + Int64($1.count) })
        check(destination.lastPathComponent == "天津罪")
        for (path, bytes) in files {
            try check(Data(contentsOf: destination.appendingPathComponent(path)) == bytes)
            try check(Data(contentsOf: source.appendingPathComponent(path)) == bytes)
        }
        try check(GameImportStore.importDirect(source, into: games).lastPathComponent == "天津罪 (2)")
        var cancel = false
        do {
            _ = try GameImportStore.importDirect(source, into: games, cancelled: { cancel }, progress: { _ in cancel = true })
            preconditionFailure("Cancelled copy was published")
        } catch { check((error as NSError).code == NSUserCancelledError) }
        try check(fm.contentsOfDirectory(atPath: games.path).sorted() == ["天津罪", "天津罪 (2)"])
        let link = source.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try GameImportStore.importDirect(source, into: games); preconditionFailure("Symlink copied") }
        catch { check((error as NSError).domain == "AetherGameImport") }
        try fm.removeItem(at: link)
        do { _ = try GameImportStore.importDirect(root, into: games); preconditionFailure("Self import allowed") }
        catch { check((error as NSError).domain == "AetherGameImport") }
        let interrupted = games.appendingPathComponent(GameImportStore.workPrefix + UUID().uuidString)
        try fm.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try Data().write(to: interrupted.appendingPathComponent(GameImportStore.workMarker))
        try GameImportStore.cleanInterrupted(in: games)
        check(!fm.fileExists(atPath: interrupted.path))
        check(fm.fileExists(atPath: destination.path))
        // Migrate a completed payload from the old app-group staging format.
        let oldJob = incoming.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: oldJob, withIntermediateDirectories: true)
        try GameImportStore.copyTree(source, to: oldJob.appendingPathComponent("payload"), cancelled: { false }, progress: { _ in })
        try JSONEncoder().encode(GameImportStore.Job(name: "旧版导入")).write(to: oldJob.appendingPathComponent(GameImportStore.metadataName))
        try check(GameImportStore.promote(oldJob, into: games).lastPathComponent == "旧版导入")
        let xp3 = source.appendingPathComponent("data.xp3")
        try check(GameImportStore.importDirect(xp3, into: games).lastPathComponent == "data.xp3")
        try check(GameImportStore.importDirect(xp3, into: games).lastPathComponent == "data (2).xp3")
        try check(GameImportStore.pending(in: incoming).isEmpty)
        let orphanID = UUID().uuidString
        let orphan = games.appendingPathComponent(".aether-import-" + orphanID)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([7]).write(to: orphan.appendingPathComponent("data"))
        try GameImportStore.revealLegacyWork(in: games)
        try check(Data(contentsOf: games.appendingPathComponent("Recovered Import-" + orphanID + "/data")) == Data([7]))
        try check(!fm.contentsOfDirectory(atPath: games.path).contains { $0.hasPrefix(".") || $0.hasPrefix(GameImportStore.workPrefix) })
        if CommandLine.arguments.contains("--large") {
            let large = root.appendingPathComponent("large.xp3")
            check(fm.createFile(atPath: large.path, contents: nil))
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: 1_073_741_824)
            try handle.close()
            let imported = try GameImportStore.importDirect(large, into: games)
            let size = try imported.resourceValues(forKeys: [.fileSizeKey]).fileSize
            check(size == 1_073_741_824)
        }
        print("GAME_IMPORT_STORE_OK: direct copy, bookmark queue, savedata, collisions, cancellation, links, recovery, XP3")
    }
}
