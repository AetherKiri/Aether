import SwiftUI
import AppKit

/// Preserve SwiftUI's window delegate while intercepting unsaved settings.
struct WindowCloseGuard: NSViewRepresentable {
    let model: ShellModel
    func makeNSView(context: Context) -> GuardView { GuardView(model: model) }
    func updateNSView(_ view: GuardView, context: Context) {}
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.detach() }

    final class GuardView: NSView, NSWindowDelegate {
        private let model: ShellModel
        private var previous: NSWindowDelegate?
        private weak var attachedWindow: NSWindow?
        init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            previous = window.delegate
            attachedWindow = window
            window.delegate = self
        }
        func detach() {
            if let window = attachedWindow, window.delegate === self { window.delegate = previous }
            previous = nil
            attachedWindow = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.settingsDirty else { return previous?.windowShouldClose?(sender) ?? true }
            model.requestLeaveSettings(action: { [weak sender] in sender?.performClose(nil) })
            return false
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previous?.responds(to: selector) == true { return previous }
            return super.forwardingTarget(for: selector)
        }
    }
}
