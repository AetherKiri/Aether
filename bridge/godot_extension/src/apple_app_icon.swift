import Foundation
#if os(iOS)
import UIKit

// Coalesce rapid interface changes and defer requests while backgrounded.
// nil is the primary Astryx light icon; Classic and AstryxDark are bundled as
// alternates on both iPhone and iPad. UIKit owns any system confirmation UI.
private final class AppIconController {
    static let shared = AppIconController()
    private var desired: String?
    private var requested = false
    private var inFlight = false
    private var activeObserver: NSObjectProtocol?

    private init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }
    }

    func apply(astryx: Bool, dark: Bool) {
        desired = astryx ? (dark ? "AstryxDark" : nil) : "Classic"
        requested = true
        update()
    }

    private func update() {
        let app = UIApplication.shared
        guard requested, !inFlight, app.applicationState == .active,
              app.supportsAlternateIcons, app.alternateIconName != desired else { return }
        let target = desired
        inFlight = true
        app.setAlternateIconName(target) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                if let error = error { NSLog("Aether app icon: %@", error.localizedDescription) }
                // A newer choice wins; a failed request is retried on the next
                // activation or user choice, never in a tight retry loop.
                if self.desired != target { self.update() }
            }
        }
    }
}
#elseif os(macOS)
import AppKit
#endif

@_cdecl("aether_app_icon_apply")
public func aetherAppIconApply(_ astryx: Bool, _ dark: Bool, _ png: UnsafePointer<UInt8>?, _ length: Int64) {
    #if os(iOS)
    DispatchQueue.main.async { AppIconController.shared.apply(astryx: astryx, dark: dark) }
    #elseif os(macOS)
    guard let png = png, length > 0 else { return }
    // Copy the Godot-owned buffer before leaving its calling thread.
    let data = Data(bytes: png, count: Int(length))
    DispatchQueue.main.async {
        guard let image = NSImage(data: data) else { return }
        NSApplication.shared.applicationIconImage = image
        // Finder's custom-icon API writes a resource fork / FinderInfo to the
        // .app, which fails strict code-signing validation. Keep the installed
        // bundle immutable; Dock and the running-app switcher use this image.
    }
    #endif
}
