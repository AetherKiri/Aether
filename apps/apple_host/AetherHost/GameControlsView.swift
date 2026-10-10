import SwiftUI

struct GameControlsView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var engine: EngineController
    private let keys: [(String, Int32)] = [("enterKey", 0x0D), ("spaceKey", 0x20), ("Esc", 0x1B),
                                           ("←", 0x25), ("↑", 0x26), ("→", 0x27), ("↓", 0x28),
                                           ("PgUp", 0x21), ("PgDn", 0x22)]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(keys, id: \.1) { title, key in
                    Button(model.text(title)) { engine.tapVirtualKey(key) }
                        .frame(minWidth: 36).accessibilityIdentifier("virtual-key-\(key)")
                }
                Divider().frame(height: 24)
                Toggle(model.text("holdControl"), isOn: Binding(
                    get: { engine.virtualControlHeld }, set: { engine.setVirtualControlHeld($0) }
                )).toggleStyle(.button).accessibilityIdentifier("virtual-control")
                Button(model.text("enterText")) { model.showGameTextEntry = true }
            }.padding(12)
        }
        .disabled(!engine.loopRunning || engine.inputSuspended)
        .onDisappear { engine.releaseVirtualKeys() }
    }
}

struct GameTextEntryView: View {
    @ObservedObject var model: ShellModel
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.text("enterText")).font(.title2.bold())
            Text(model.text("enterTextHelp")).foregroundStyle(.secondary)
            TextField(model.text("enterText"), text: $text).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { submit() }
            HStack {
                Spacer()
                Button(model.text("cancel")) { model.showGameTextEntry = false }.keyboardShortcut(.cancelAction)
                Button(model.text("sendText")) { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(GameTextInput.scalars(text).isEmpty)
            }
        }.padding(24).frame(width: 460).onAppear { focused = true }
    }
    private func submit() {
        guard !GameTextInput.scalars(text).isEmpty else { return }
        do { try model.engine.commitGameText(text); model.showGameTextEntry = false }
        catch { model.showGameTextEntry = false; model.error = error.localizedDescription }
    }
}
