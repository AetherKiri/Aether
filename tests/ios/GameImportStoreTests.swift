import Foundation

// Run on macOS with GameImportStore.swift; exercises real files, not mocks.
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
        let files = ["savedata/slot01.sav": Data([0, 1, 2, 255]), ".patch": Data("补丁".utf8),
                     "data.xp3": Data(repeating: 42, count: 2_500_000)]
        for (path, bytes) in files { try bytes.write(to: source.appendingPathComponent(path)) }
        var copied: Int64 = 0
        let job = try GameImportStore.receive(source, into: incoming, progress: { copied = $0 })
        precondition(copied == files.values.reduce(0) { $0 + Int64($1.count) })
        precondition(!fm.fileExists(atPath: games.path))
        let destination = try GameImportStore.promote(job, into: games)
        precondition(destination.lastPathComponent == "天津罪")
        for (path, bytes) in files {
            try check(Data(contentsOf: destination.appendingPathComponent(path)) == bytes)
            try check(Data(contentsOf: source.appendingPathComponent(path)) == bytes)
        }
        let duplicate = try GameImportStore.receive(source, into: incoming)
        try check(GameImportStore.promote(duplicate, into: games).lastPathComponent == "天津罪 (2)")

        var cancel = false
        do {
            _ = try GameImportStore.receive(source, into: incoming, cancelled: { cancel }, progress: { _ in cancel = true })
            preconditionFailure("Cancelled copy was published")
        } catch { precondition((error as NSError).code == NSUserCancelledError) }
        try check(fm.contentsOfDirectory(atPath: incoming.path).isEmpty)

        let link = source.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try GameImportStore.receive(source, into: incoming); preconditionFailure("Symlink copied") }
        catch { precondition((error as NSError).domain == "AetherGameImport") }
        try fm.removeItem(at: link)
        try check(fm.contentsOfDirectory(atPath: incoming.path).isEmpty)
        do { _ = try GameImportStore.receive(root, into: incoming); preconditionFailure("Self import allowed") }
        catch { precondition((error as NSError).domain == "AetherGameImport") }

        // A kill between the cross-container move and publication resumes once.
        let interrupted = try GameImportStore.receive(source, suggestedName: "恢复", into: incoming)
        try fm.moveItem(at: interrupted.appendingPathComponent("payload"),
                        to: games.appendingPathComponent(".aether-import-" + interrupted.lastPathComponent))
        try check(GameImportStore.promote(interrupted, into: games).lastPathComponent == "恢复")
        // A kill after publication but before journal cleanup does not duplicate.
        let published = try GameImportStore.receive(source, suggestedName: "已完成", into: incoming)
        try fm.moveItem(at: published.appendingPathComponent("payload"), to: games.appendingPathComponent("已完成"))
        try JSONEncoder().encode(GameImportStore.Job(name: "已完成", destination: "已完成"))
            .write(to: published.appendingPathComponent(GameImportStore.metadataName))
        try check(GameImportStore.promote(published, into: games).lastPathComponent == "已完成")
        precondition(!fm.fileExists(atPath: games.appendingPathComponent("已完成 (2)").path))

        let xp3 = source.appendingPathComponent("data.xp3")
        let archive = try GameImportStore.receive(xp3, into: incoming)
        try check(GameImportStore.promote(archive, into: games).lastPathComponent == "data.xp3")
        let archive2 = try GameImportStore.receive(xp3, into: incoming)
        try check(GameImportStore.promote(archive2, into: games).lastPathComponent == "data (2).xp3")
        try check(GameImportStore.pending(in: incoming).isEmpty)
        print("GAME_IMPORT_STORE_OK: full copy, savedata, hidden files, collisions, cancellation, links, recovery, XP3")
    }
}
