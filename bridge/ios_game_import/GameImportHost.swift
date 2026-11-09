import Foundation
import UIKit

@objc(AetherGameImportHost)
final class GameImportHost: NSObject, @unchecked Sendable {
    @objc static let shared = GameImportHost()
    private let worker = DispatchQueue(label: "org.aether.game-import", qos: .userInitiated)
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var draining = false
    private var activeURLs = Set<String>()

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var games: URL { documents.appendingPathComponent("Games", isDirectory: true) }
    private var localIncoming: URL {
        // Outside Games: unfinished imports never appear as playable entries.
        documents.appendingPathComponent(".AetherIncoming", isDirectory: true)
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
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.lock.lock()
                self.activeURLs.remove(key)
                self.lock.unlock()
            }
            do {
                guard !GameImportStore.isInside(self.games, url) else {
                    throw GameImportStore.failure("The Games directory or its parent cannot be imported into itself.")
                }
                let job = try GameImportStore.receive(url, into: self.localIncoming, progress: { bytes in
                    self.emit("progress", name: url.lastPathComponent, bytes: bytes)
                })
                let destination = try GameImportStore.promote(job, into: self.games)
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

    @objc func consumePending() {
        lock.lock()
        guard !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        worker.async {
            defer {
                self.lock.lock()
                self.draining = false
                self.lock.unlock()
            }
            var roots = [self.localIncoming]
            if let shared = try? GameImportStore.sharedRoot() { roots.append(shared) }
            for root in roots {
                do {
                    for job in try GameImportStore.pending(in: root) {
                        do {
                            self.emit("progress")
                            let destination = try GameImportStore.promote(job, into: self.games)
                            self.emit("complete", name: destination.lastPathComponent, path: destination.path)
                        } catch {
                            self.emit("error", error: error.localizedDescription)
                        }
                    }
                } catch {
                    self.emit("error", error: error.localizedDescription)
                }
            }
        }
    }
}
