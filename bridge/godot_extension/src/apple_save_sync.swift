import Foundation
#if os(iOS)
import UIKit
#endif

private final class AetherCloudSaveSync: @unchecked Sendable {
    static let shared = AetherCloudSaveSync()
    private let worker = DispatchQueue(label: "org.aether.save-sync", qos: .utility)
    private let lock = NSLock()
    private var result: String?
    private var busy = false
    private var timer: DispatchSourceTimer?
    private var local: URL?
    private var remote: URL?
    private var uploaded: AetherSaveSyncStore.Snapshot?
    private var lastError = ""
    private var account: NSObjectProtocol?

    func begin(_ action: String, path: String, game: String) -> Bool {
        guard ["enable", "start", "stop", "disable", "flush"].contains(action) else { return false }
        lock.lock()
        if busy && action != "stop" && action != "disable" && action != "flush" { lock.unlock(); return false }
        if action == "enable" || action == "start" { busy = true; result = nil }
        lock.unlock()
#if os(iOS)
        let background = AetherSaveSyncBackgroundTask()
#endif
        worker.async {
#if os(iOS)
            defer { background.finish() }
#endif
            if action == "stop" || action == "disable" || action == "flush" {
                if action != "disable" { self.check() }
                if action != "flush" {
                    self.reset()
                    if action == "disable" { self.finish(["status": "disabled"]) }
                }
                return
            }
            self.reset()
            do {
                guard path.hasPrefix("/"), !game.isEmpty, !game.hasPrefix("."), !game.contains("/"), !game.contains("\\"), !game.contains("\0") else { throw AetherSaveSyncStore.failure("Invalid game save path.") }
                let fm = FileManager.default
                guard let identifier = Bundle.main.object(forInfoDictionaryKey: "AetherSaveCloudContainer") as? String,
                      let account = fm.ubiquityIdentityToken,
                      let container = fm.url(forUbiquityContainerIdentifier: identifier) else {
                    throw AetherSaveSyncStore.failure("iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive for Aether.")
                }
                let local = URL(fileURLWithPath: path, isDirectory: true)
#if os(iOS)
                let games = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Games").resolvingSymlinksInPath().path
                guard local.lastPathComponent == "savedata", local.resolvingSymlinksInPath().path.hasPrefix(games + "/"),
                      local.deletingLastPathComponent().resolvingSymlinksInPath().path != games else { throw AetherSaveSyncStore.failure("Each game must have its own folder inside Games before enabling save sync.") }
#endif
                let remote = container.appendingPathComponent("Documents/Games", isDirectory: true)
                    .appendingPathComponent(game, isDirectory: true).appendingPathComponent("savedata", isDirectory: true)
                try AetherSaveSyncStore.recoverLocal(local)
                var downloaded = false
                if fm.fileExists(atPath: remote.path) {
                    // Do not nest file read coordination inside a directory
                    // write lock: iCloud providers can otherwise deadlock.
                    try self.coordinated(remote, writing: true) { cloud in
                        try AetherSaveSyncStore.cleanWork(in: cloud, prefix: "Save Sync File-", recursive: true)
                    }
                    try self.materialize(remote)
                    try self.coordinated(remote, writing: false) { cloud in
                        try AetherSaveSyncStore.replaceLocal(from: cloud, to: local)
                        downloaded = true
                    }
                } else {
                    try self.coordinated(remote, writing: true) { cloud in
                        guard !fm.fileExists(atPath: cloud.path) else { throw AetherSaveSyncStore.failure("Cloud saves appeared during setup. Please retry to download them.") }
                        try fm.createDirectory(at: local, withIntermediateDirectories: true)
                        _ = try AetherSaveSyncStore.upload(from: local, to: cloud, previous: nil)
                    }
                }
                self.account = account
                self.local = local; self.remote = remote
                self.uploaded = try AetherSaveSyncStore.snapshot(local)
                self.lastError = ""
                if action == "start" {
                    let timer = DispatchSource.makeTimerSource(queue: self.worker)
                    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
                    timer.setEventHandler { [weak self] in self?.check() }
                    self.timer = timer; timer.resume()
                }
                self.finish(["status": "ready", "downloaded": downloaded])
            } catch { self.finish(["status": "error", "error": error.localizedDescription]) }
        }
        return true
    }

    private func reset() {
        timer?.cancel(); timer = nil
        local = nil; remote = nil; uploaded = nil; account = nil
    }

    private func coordinated(_ url: URL, writing: Bool, work: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        let timeout = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        var coordinationError: NSError?, failure: Error?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { target in
                do { try work(target) } catch { failure = error }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
                do { try work(target) } catch { failure = error }
            }
        }
        if let error = failure ?? coordinationError { throw error }
    }

    private func materialize(_ folder: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .ubiquitousItemHasUnresolvedConflictsKey]) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .ubiquitousItemHasUnresolvedConflictsKey])
            guard values.isSymbolicLink != true, values.ubiquitousItemHasUnresolvedConflicts != true else { throw AetherSaveSyncStore.failure("The cloud save has a conflicting version or invalid link.") }
            if values.isDirectory == true { try materialize(item) }
            else { try coordinated(item, writing: false) { _ in } }
        }
    }

    private func check() {
        guard let local, let remote else { return }
        do {
            guard let currentAccount = FileManager.default.ubiquityIdentityToken,
                  account?.isEqual(currentAccount) == true else {
                reset()
                throw AetherSaveSyncStore.failure("The iCloud account changed. Restart the game to reconnect.")
            }
            let current = try AetherSaveSyncStore.snapshot(local)
            guard current != uploaded else { return }
            try coordinated(remote, writing: true) { cloud in
                self.uploaded = try AetherSaveSyncStore.upload(from: local, to: cloud, previous: self.uploaded)
            }
            lastError = ""
        } catch {
            if error.localizedDescription != lastError {
                lastError = error.localizedDescription
                finish(["status": "sync_error", "error": lastError])
            }
            // Keep the previous fingerprint so the next second retries.
        }
    }

    private func finish(_ value: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: value)
        lock.lock(); defer { lock.unlock() }
        result = data.flatMap { String(data: $0, encoding: .utf8) }
        busy = false
    }
    func takeResult() -> UnsafeMutablePointer<CChar>? {
        lock.lock(); defer { lock.unlock() }
        let value = result; result = nil
        return value.map { strdup($0) }
    }
}

#if os(iOS)
/// Give the final/background flush time to finish without blocking the UI.
private final class AetherSaveSyncBackgroundTask: @unchecked Sendable {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        DispatchQueue.main.async {
            self.identifier = UIApplication.shared.beginBackgroundTask(withName: "Save sync") { self.finish() }
        }
    }
    func finish() {
        DispatchQueue.main.async {
            if self.identifier != .invalid {
                UIApplication.shared.endBackgroundTask(self.identifier)
                self.identifier = .invalid
            }
        }
    }
}
#endif

@_cdecl("aether_cloud_save_sync_begin")
public func aetherCloudSaveSyncBegin(_ action: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ game: UnsafePointer<CChar>?) -> Int32 {
    guard let action, let path, let game else { return 0 }
    return AetherCloudSaveSync.shared.begin(String(cString: action), path: String(cString: path), game: String(cString: game)) ? 1 : 0
}
@_cdecl("aether_cloud_save_sync_take_result")
public func aetherCloudSaveSyncTakeResult() -> UnsafeMutablePointer<CChar>? { AetherCloudSaveSync.shared.takeResult() }
