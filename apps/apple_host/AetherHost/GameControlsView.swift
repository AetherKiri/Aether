import SwiftUI

/// Godot-style in-game virtual controls: a top-right entry button toggles the
/// key panel, the panel dims with the configured opacity, and the mouse-mode
/// cursor handle stays fully opaque because it carries the pointer.
struct GameControlsView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var engine: EngineController
    @State private var lastDragTranslation: CGSize = .zero
    private let keys: [(String, Int32)] = [("enterKey", 0x0D), ("spaceKey", 0x20), ("Esc", 0x1B),
                                           ("←", 0x25), ("↑", 0x26), ("→", 0x27), ("↓", 0x28),
                                           ("PgUp", 0x21), ("PgDn", 0x22)]

    private var presentation: VirtualControlsPresentation {
        VirtualControlsPresentation(
            enabled: model.showVirtualControls,
            entryAllowed: model.settings.virtualControlMenuEnabled,
            panelOpen: model.virtualPanelOpen,
            mode: VirtualControlMode.normalized(model.settings.virtualControlMode) ?? .mouse,
            opacity: model.settings.virtualControlKeyboardOpacity)
    }

    var body: some View {
        GeometryReader { geometry in
            let presentation = self.presentation
            let scale = CGSize(width: engine.frameSize.width / max(1, geometry.size.width),
                               height: engine.frameSize.height / max(1, geometry.size.height))
            VStack(spacing: 8) {
                HStack {
                    Spacer(minLength: 0)
                    if presentation.showsEntry {
                        Button { model.toggleVirtualPanel() } label: {
                            Label(model.text("virtualControls"),
                                  systemImage: model.virtualPanelOpen ? "xmark.circle" : "keyboard")
                                .labelStyle(.iconOnly)
                        }
                        .help(model.text(model.virtualPanelOpen ? "virtualControlsHide" : "virtualControlsShow"))
                        .accessibilityIdentifier("virtual-controls-entry")
                    }
                }
                Spacer(minLength: 0)
                if presentation.showsPanel {
                    panel(presentation, scale: scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func panel(_ presentation: VirtualControlsPresentation, scale: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(model.text("virtualModeLabel") + " · " + model.text(presentation.mode.textKey))
                    .font(.caption).foregroundStyle(.white)
                Button(model.text("virtualModeSwitch")) { toggleMode(presentation.mode) }
                    .controlSize(.small)
                    .help(model.text(presentation.mode.helpKey))
                Spacer(minLength: 0)
                if presentation.showsPointerHandle {
                    Button { engine.clickVirtualPointer() } label: {
                        Label(model.text("virtualClick"), systemImage: "cursorarrow.click")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("virtual-click")
                }
            }
            .opacity(presentation.keyOpacity)
            HStack(spacing: 10) {
                // The pointer handle carries the click position, so it stays
                // fully opaque while the key caps dim (Godot's rule).
                if presentation.showsPointerHandle {
                    cursorHandle(scale: scale)
                }
                Group {
                    ForEach(keys, id: \.1) { title, key in
                        Button(model.text(title)) { engine.tapVirtualKey(key) }
                            .frame(minWidth: 36).accessibilityIdentifier("virtual-key-\(key)")
                    }
                    Divider().frame(height: 24)
                    Toggle(model.text("holdControl"), isOn: Binding(
                        get: { engine.virtualControlHeld }, set: { engine.setVirtualControlHeld($0) }
                    )).toggleStyle(.button).accessibilityIdentifier("virtual-control")
                    Button(model.text("enterText")) { model.showGameTextEntry = true }
                }
                .opacity(presentation.keyOpacity)
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .disabled(!engine.loopRunning || engine.inputSuspended)
        .padding(.horizontal, 12).padding(.bottom, 12)
        .onDisappear { engine.releaseVirtualKeys() }
    }

    /// Draggable virtual pointer. Drag deltas are scaled from view points into
    /// logical canvas pixels so the engine receives canvas coordinates.
    private func cursorHandle(scale: CGSize) -> some View {
        Image(systemName: "cursorarrow.motionlines")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.65), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
            .accessibilityLabel(model.text("virtualCursor"))
            .accessibilityIdentifier("virtual-cursor")
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = (value.translation.width - lastDragTranslation.width) * scale.width
                    let dy = (value.translation.height - lastDragTranslation.height) * scale.height
                    lastDragTranslation = value.translation
                    if dx != 0 || dy != 0 { engine.moveVirtualPointer(dx: dx, dy: dy) }
                }
                .onEnded { _ in lastDragTranslation = .zero })
    }

    private func toggleMode(_ mode: VirtualControlMode) {
        model.setVirtualControlMode(mode == .mouse ? .touch : .mouse)
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
