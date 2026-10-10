import SwiftUI
import AppKit

@main
struct AetherHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @StateObject private var shell = ShellModel()
    var body: some Scene {
        Window("Aether", id: "main") {
            ContentView(model: shell, engine: shell.engine)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands { ShellCommands(model: shell) }
    }
}

/// Test/benchmark launches are unattended; with AETHER_HOST_ACTIVATE=1 the
/// window is brought forward so presentation is not gated by window occlusion.
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["AETHER_HOST_ACTIVATE"] == "1" else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
