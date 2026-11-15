import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Access comes from the system directory picker. This works with the user's
// existing iCloud Drive on both platforms, without a second app-owned cloud.
private final class AetherSaveTransfer: NSObject, @unchecked Sendable {
    static let shared = AetherSaveTransfer()
    private let bookmarkKey = "Aether.SaveTransfer.iCloudDirectory.v1"
    private let lock = NSLock()
    private var busy = false
    private var result: String?
    private var request: (action: String, path: String, folder: String, title: String)?
#if os(iOS)
    private var picker: UIDocumentPickerViewController?
#else
    private var picker: NSOpenPanel?
    private var sharing: NSSharingServicePicker?
#endif

    func begin(action: String, path: String, folder: String, title: String) -> Bool {
        guard ["share", "upload", "download"].contains(action), path.hasPrefix("/"),
              !folder.isEmpty, !folder.contains("/"), !folder.contains("\\"),
              folder != ".", folder != ".." else { return false }
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true
        result = nil
        lock.unlock()
        DispatchQueue.main.async {
            self.request = (action, path, folder, title)
            if action == "share" {
                self.share(URL(fileURLWithPath: path), title: title)
            } else if let directory = self.restoreDirectory() {
                self.transfer(directory)
            } else {
                self.chooseDirectory(title: title)
            }
        }
        return true
    }

    func takeResult() -> UnsafeMutablePointer<CChar>? {
        lock.lock()
        let value = result
        result = nil
        lock.unlock()
        return value.map { strdup($0) } ?? nil
    }

    private func finish(_ status: String, error: String = "") {
        let data = try? JSONSerialization.data(withJSONObject: ["status": status, "error": error])
        lock.lock()
        result = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"status\":\"error\"}"
        busy = false
        lock.unlock()
    }

    private func restoreDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        do {
            var stale = false
#if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
#else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
#endif
            let url = try URL(resolvingBookmarkData: data, options: options,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { UserDefaults.standard.removeObject(forKey: bookmarkKey); return nil }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
    }

    private func transfer(_ directory: URL) {
        guard let request else { finish("error"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            let manager = FileManager.default
            do {
                let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
                guard properties.isDirectory == true, properties.isUbiquitousItem == true else {
                    UserDefaults.standard.removeObject(forKey: self.bookmarkKey)
                    self.finish("not_icloud")
                    return
                }
#if os(macOS)
                let options: URL.BookmarkCreationOptions = [.withSecurityScope]
#else
                let options: URL.BookmarkCreationOptions = [.minimalBookmark]
#endif
                let bookmark = try directory.bookmarkData(options: options,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: self.bookmarkKey)
                // Each game owns exactly one named subdirectory; never enumerate
                // or download another game's saves.
                let game = directory.appendingPathComponent(request.folder, isDirectory: true)
                let remote = game.appendingPathComponent("saves.zip")
                let local = URL(fileURLWithPath: request.path)
                let coordinator = NSFileCoordinator()
                let timeout = DispatchWorkItem { coordinator.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
                defer { timeout.cancel() }
                var coordinationError: NSError?
                var operationError: Error?
                if request.action == "upload" {
                    coordinator.coordinate(writingItemAt: game, options: .forMerging,
                        error: &coordinationError) { target in
                        do {
                            try manager.createDirectory(at: target, withIntermediateDirectories: true)
                            let destination = target.appendingPathComponent("saves.zip")
                            if (try? destination.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?
                                .ubiquitousItemHasUnresolvedConflicts == true {
                                throw NSError(domain: "AetherSaves", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "iCloud has conflicting versions of this save archive"])
                            }
                            let bytes = try Data(contentsOf: local, options: .mappedIfSafe)
                            try bytes.write(to: destination, options: .atomic)
                        } catch { operationError = error }
                    }
                } else {
                    // Coordination materializes iCloud placeholders before copying.
                    coordinator.coordinate(readingItemAt: remote, options: [],
                        error: &coordinationError) { source in
                        do {
                            let properties = try source.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemHasUnresolvedConflictsKey])
                            guard properties.ubiquitousItemHasUnresolvedConflicts != true else {
                                throw NSError(domain: "AetherSaves", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "iCloud has conflicting versions of this save archive"])
                            }
                            guard let size = properties.fileSize, size <= 1024 * 1024 * 1024 else {
                                throw NSError(domain: "AetherSaves", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "The save archive is too large"])
                            }
                            try manager.copyItem(at: source, to: local)
                        } catch { operationError = error }
                    }
                }
                if let failure = operationError ?? coordinationError {
                    let code = (failure as NSError).code
                    self.finish(code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError
                        ? "not_found" : "error", error: failure.localizedDescription)
                } else {
                    // Upload means handed to iCloud Drive; the OS owns network sync.
                    self.finish(request.action == "upload" ? "uploaded" : "downloaded")
                }
            } catch {
                UserDefaults.standard.removeObject(forKey: self.bookmarkKey)
                self.finish("error", error: error.localizedDescription)
            }
        }
    }

#if os(iOS)
    private func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        var controller = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller
    }

    private func chooseDirectory(title: String) {
        guard let presenter = presenter() else { finish("error"); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.title = title
        picker.allowsMultipleSelection = false
        self.picker = picker
        presenter.present(picker, animated: true)
    }

    private func share(_ file: URL, title: String) {
        guard let presenter = presenter() else { finish("error"); return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.setValue(title, forKey: "subject")
        sheet.completionWithItemsHandler = { _, completed, _, error in
            self.finish(error != nil ? "error" : completed ? "shared" : "cancelled",
                        error: error?.localizedDescription ?? "")
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }
#else
    private func chooseDirectory(title: String) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        picker = panel
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            self.picker = nil
            if response == .OK, let url = panel.url { self.transfer(url) }
            else { self.finish("cancelled") }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func share(_ file: URL, title: String) {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { finish("error"); return }
        let picker = NSSharingServicePicker(items: [file])
        picker.delegate = self
        sharing = picker
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
#endif
}

#if os(iOS)
extension AetherSaveTransfer: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picker = nil
        if let url = urls.first { transfer(url) } else { finish("cancelled") }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        picker = nil
        finish("cancelled")
    }
}
#else
extension AetherSaveTransfer: NSSharingServicePickerDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // A chosen service owns the next sheet. Keep the exported file available.
        finish(service == nil ? "cancelled" : "presented")
    }
}
#endif

@_cdecl("aether_save_transfer_begin")
public func aetherSaveTransferBegin(_ action: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?,
                                   _ folder: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?) -> Int32 {
    guard let action, let path, let folder, let title else { return 0 }
    return AetherSaveTransfer.shared.begin(action: String(cString: action), path: String(cString: path),
        folder: String(cString: folder), title: String(cString: title)) ? 1 : 0
}

@_cdecl("aether_save_transfer_take_result")
public func aetherSaveTransferTakeResult() -> UnsafeMutablePointer<CChar>? {
    return AetherSaveTransfer.shared.takeResult()
}
