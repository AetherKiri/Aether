import Foundation
import UIKit

@objc(AetherGameImportHost)
final class GameImportHost: NSObject, @unchecked Sendable {
    @objc static let shared = GameImportHost()
    private let worker = DispatchQueue(label: "org.aether.game-import", qos: .userInitiated)
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var draining = false
    private var cleaned = false
    private var activeURLs = Set<String>()

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var games: URL { documents.appendingPathComponent("Games", isDirectory: true) }
    private var localIncoming: URL {
        // Migration only: new imports never write here.
        documents.appendingPathComponent("Import Recovery", isDirectory: true)
    }

    private func emit(_ status: String, name: String = "", bytes: Int64 = 0, path: String = "", error: String = "") {
        lock.lock()
        defer { lock.unlock() }
        let event: [String: Any] = ["status": status, "name": name, "bytes": bytes, "path": path, "error": error]
        if status == "progress", events.last?["status"] as? String == status {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
    }

    @objc func takeEventJSON() -> String? {
        lock.lock()
        let event = events.isEmpty ? nil : events.removeFirst()
        lock.unlock()
        guard let event, let data = try? JSONSerialization.data(withJSONObject: event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @objc func acceptURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let key = url.standardizedFileURL.path
        lock.lock()
        let inserted = activeURLs.insert(key).inserted
        lock.unlock()
        guard inserted else { return true }
        // Retain the security scope before returning to the OS's open-URL
        // callback; the copy itself runs off the rendering/UI thread.
        let scoped = url.startAccessingSecurityScopedResource()
        emit("progress", name: url.lastPathComponent)
        worker.async {
            let background = GameImportBackgroundTask()
            defer {
                background.finish()
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.lock.lock()
                self.activeURLs.remove(key)
                self.lock.unlock()
            }
            do {
                guard !GameImportStore.isInside(self.games, url) else {
                    throw GameImportStore.failure("The Games directory or its parent cannot be imported into itself.")
                }
                try self.cleanInterrupted()
                let destination = try GameImportStore.importDirect(url, into: self.games, cancelled: { background.isCancelled }, progress: { bytes in
                    self.emit("progress", name: url.lastPathComponent, bytes: bytes)
                })
                self.emit("complete", name: destination.lastPathComponent, path: destination.path)
                // Open-in delivery may leave an OS-owned copy in Inbox. Remove
                // only that copy after success, never the external source.
                let inbox = self.documents.appendingPathComponent("Inbox", isDirectory: true)
                if GameImportStore.isInside(url, inbox), url.standardizedFileURL != inbox.standardizedFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                self.emit("error", name: url.lastPathComponent, error: error.localizedDescription)
            }
        }
        return true
    }

    private func cleanInterrupted() throws {
        guard !cleaned else { return }
        try GameImportStore.cleanInterrupted(in: games)
        let old = documents.appendingPathComponent(".AetherIncoming", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path) {
            try fm.createDirectory(at: localIncoming, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                let target = localIncoming.appendingPathComponent(item.lastPathComponent)
                let destination = fm.fileExists(atPath: target.path) ? localIncoming.appendingPathComponent("Recovered-" + UUID().uuidString) : target
                try fm.moveItem(at: item, to: destination)
            }
            if try fm.contentsOfDirectory(atPath: old.path).isEmpty { try fm.removeItem(at: old) }
        }
        cleaned = true
    }

    @objc func consumePending() {
        lock.lock()
        guard !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        worker.async {
            let background = GameImportBackgroundTask()
            defer {
                background.finish()
                self.lock.lock()
                self.draining = false
                self.lock.unlock()
            }
            do { try self.cleanInterrupted() } catch { self.emit("error", error: error.localizedDescription) }
            var roots = [self.localIncoming]
            if let shared = try? GameImportStore.sharedRoot() { roots.append(shared) }
            for root in roots {
                do {
                    try GameImportStore.cleanLegacyPartials(in: root)
                    for job in try GameImportStore.pending(in: root) {
                        if background.isCancelled { break }
                        do {
                            self.emit("progress")
                            let destination = try GameImportStore.promote(job, into: self.games, cancelled: { background.isCancelled }, progress: { bytes in self.emit("progress", bytes: bytes) })
                            self.emit("complete", name: destination.lastPathComponent, path: destination.path)
                        } catch {
                            self.emit("error", error: error.localizedDescription)
                        }
                    }
                } catch {
                    self.emit("error", error: error.localizedDescription)
                }
            }
            do { try GameImportStore.revealLegacyWork(in: self.games) }
            catch { self.emit("error", error: error.localizedDescription) }
        }
    }
}

private final class GameImportBackgroundTask: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    init() {
        DispatchQueue.main.async {
            self.identifier = UIApplication.shared.beginBackgroundTask(withName: "Import game") {
                self.lock.lock(); self.cancelled = true; self.lock.unlock()
                self.finish()
            }
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
