import SwiftUI

@main
struct AetherHostApp: App {
    @StateObject private var shell = ShellModel()
    var body: some Scene {
        Window("Aether", id: "main") {
            ContentView(model: shell, engine: shell.engine)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands { ShellCommands(model: shell) }
    }
}
