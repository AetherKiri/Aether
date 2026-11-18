import Foundation

@main struct SaveSyncStoreTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AetherSaveSyncTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Games/游戏/savedata")
        let remote = root.appendingPathComponent("aether/Games/游戏/savedata")
        let other = root.appendingPathComponent("aether/Games/another/savedata")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([99]).write(to: other.appendingPathComponent("slot"))
        try Data([1,2,3]).write(to: local.appendingPathComponent("slot"))
        var uploaded = try AetherSaveSyncStore.upload(from: local, to: remote, previous: nil)
        let unchanged = try remote.appendingPathComponent("slot").resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        _ = try AetherSaveSyncStore.upload(from: local, to: remote, previous: uploaded)
        let still = try remote.appendingPathComponent("slot").resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        precondition(String(describing: unchanged) == String(describing: still), "Unchanged cloud files must not be replaced")
        try Data([4,5,6,7]).write(to: local.appendingPathComponent("slot"))
        try fm.createDirectory(at: local.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data([8]).write(to: local.appendingPathComponent("nested/new"))
        uploaded = try AetherSaveSyncStore.upload(from: local, to: remote, previous: uploaded)
        try check(Data(contentsOf: remote.appendingPathComponent("slot")) == Data([4,5,6,7]))
        try fm.removeItem(at: local.appendingPathComponent("slot"))
        _ = try AetherSaveSyncStore.upload(from: local, to: remote, previous: uploaded)
        precondition(!fm.fileExists(atPath: remote.appendingPathComponent("slot").path))
        try Data([33]).write(to: local.appendingPathComponent("local-only"))
        try AetherSaveSyncStore.replaceLocal(from: remote, to: local)
        precondition(!fm.fileExists(atPath: local.appendingPathComponent("local-only").path))
        try check(Data(contentsOf: local.appendingPathComponent("nested/new")) == Data([8]))
        try check(Data(contentsOf: other.appendingPathComponent("slot")) == Data([99]))
        let link = local.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: other)
        do { _ = try AetherSaveSyncStore.upload(from: local, to: remote, previous: nil); preconditionFailure("Link accepted") }
        catch { precondition((error as NSError).domain == "AetherSaveSync") }
        try fm.removeItem(at: link)
        let missing = root.appendingPathComponent("missing/savedata")
        do { _ = try AetherSaveSyncStore.upload(from: missing, to: remote, previous: uploaded); preconditionFailure("Missing saves must not erase the cloud") }
        catch { precondition((error as NSError).domain == "AetherSaveSync") }
        try check(Data(contentsOf: remote.appendingPathComponent("nested/new")) == Data([8]))
        let parent = local.deletingLastPathComponent()
        let abandoned = parent.appendingPathComponent("Save Sync Incoming-" + UUID().uuidString)
        try fm.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([1]).write(to: abandoned.appendingPathComponent("partial"))
        try fm.moveItem(at: local, to: parent.appendingPathComponent("Save Sync Previous"))
        try AetherSaveSyncStore.recoverLocal(local)
        try AetherSaveSyncStore.replaceLocal(from: remote, to: local)
        check(!fm.fileExists(atPath: abandoned.path))
        try check(fm.contentsOfDirectory(atPath: local.deletingLastPathComponent().path) == ["savedata"])
        print("SAVE_SYNC_STORE_OK: upload, unchanged files, nested saves, deletions, replace, game isolation, links, cleanup")
    }
}
