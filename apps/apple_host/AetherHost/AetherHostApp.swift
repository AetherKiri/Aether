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
                .background(WindowCloseGuard(model: shell))
                .onAppear { appDelegate.model = shell }
        }
        .commands { ShellCommands(model: shell) }
    }
}

/// Test/benchmark launches are unattended; with AETHER_HOST_ACTIVATE=1 the
/// window is brought forward so presentation is not gated by window occlusion.
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ShellModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.settingsDirty else { return .terminateNow }
        if model.confirmDiscardSettings { return .terminateCancel }
        model.requestLeaveSettings(action: { sender.reply(toApplicationShouldTerminate: true) },
                                   cancel: { sender.reply(toApplicationShouldTerminate: false) })
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["AETHER_HOST_ACTIVATE"] == "1" else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    /// Commits the running session's play time and destroys the engine before
    /// the process exits; without this the last session would be lost.
    func applicationWillTerminate(_ notification: Notification) {
        model?.closeActiveSession()
    }
}
