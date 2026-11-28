import UIKit
import UniformTypeIdentifiers

@objc(GameImportActionViewController)
final class GameImportActionViewController: UIViewController, @unchecked Sendable {
    private let stateLock = NSLock()
    private var cancelled = false
    private var providerProgress: Progress?
    private var started = false
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let button = UIButton(type: .system)

    private func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 300)
        let title = UILabel()
        title.text = text("import.title", "Send to Aether Visual Novels")
        title.font = .preferredFont(forTextStyle: .headline)
        title.numberOfLines = 0
        title.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .body)
        status.numberOfLines = 0
        status.textAlignment = .center
        button.setTitle(text("import.cancel", "Cancel"), for: .normal)
        button.addTarget(self, action: #selector(cancelOrFinish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, spinner, status, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        spinner.startAnimating()
        status.text = text("import.preparing", "Receiving shared items…")
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        DispatchQueue.global(qos: .userInitiated).async { self.receive(providers) }
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    @objc private func cancelOrFinish() {
        if !spinner.isAnimating {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        stateLock.lock()
        cancelled = true
        let progress = providerProgress
        stateLock.unlock()
        progress?.cancel()
        button.isEnabled = false
        status.text = text("import.cancelling", "Cancelling…")
    }

    private func receive(_ providers: [NSItemProvider]) {
        var received = 0
        var lastError: Error?
        do {
            guard !providers.isEmpty else { throw GameImportStore.failure("No files or folders were shared.") }
            let incoming = try GameImportStore.sharedRoot()
            for provider in providers {
                if isCancelled() { break }
                let semaphore = DispatchSemaphore(value: 0)
                let name = provider.suggestedName
                let finish: (URL?, Bool, Error?) -> Void = { url, inPlace, error in
                    defer { semaphore.signal() }
                    do {
                        if let error { throw error }
                        guard let url else { throw GameImportStore.failure("The sharing app did not provide a file URL.") }
                        let receive = inPlace ? GameImportStore.receive : GameImportStore.receiveTemporaryFile
                        _ = try receive(url, name, incoming, { self.isCancelled() }, { bytes in
                                DispatchQueue.main.async {
                                    self.status.text = "\(name ?? url.lastPathComponent)\n\(String(format: "%.1f MB", Double(bytes) / 1_048_576))"
                                }
                            })
                        received += 1
                    } catch { lastError = error }
                }
                let types = provider.registeredTypeIdentifiers
                let folderType = types.first { UTType($0)?.conforms(to: .directory) == true }
                let dataType = types.first { UTType($0)?.conforms(to: .data) == true && $0 != UTType.fileURL.identifier }
                let progress: Progress?
                if folderType == nil && provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        finish(url, true, error)
                    }
                    progress = nil
                } else if let type = folderType ?? dataType {
                    progress = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, error in
                        finish(url, inPlace, error)
                    }
                } else {
                    throw GameImportStore.failure(NSLocalizedString("import.unsupported", value: "Select a game folder or an archive file.", comment: ""))
                }
                stateLock.lock()
                providerProgress = progress
                let stop = cancelled
                stateLock.unlock()
                if stop { progress?.cancel() }
                semaphore.wait()
                if lastError != nil { break }
            }
        } catch { lastError = error }
        let count = received
        let error = lastError
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.button.isEnabled = true
            self.button.setTitle(self.text("import.done", "Done"), for: .normal)
            if self.isCancelled() && count == 0 {
                self.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            } else if let error {
                self.status.text = "\(self.text("import.failed", "Could not finish importing."))\n\(error.localizedDescription)"
                if count > 0 { self.status.text! += "\n" + self.text("import.open_aether", "Open Aether to add the received items to Games.") }
            } else {
                self.status.text = String(format: self.text("import.received", "Received %d item(s). Open Aether to add them to Games automatically."), count)
            }
        }
    }
}
