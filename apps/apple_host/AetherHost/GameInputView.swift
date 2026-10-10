import AppKit
import SwiftUI

// Game-surface input capture.
//
// SwiftUI hosting can swallow mouse events before they reach a representable's
// NSView (observed: real clicks never hit the view, while programmatic sends
// worked). A local NSEvent monitor sees events before dispatch and is
// independent of SwiftUI hit testing. The NSView below stays as the geometry
// anchor (canvas rect, coordinate conversion) and first-responder holder.
struct GameInputView: NSViewRepresentable {
    var contentSize: CGSize
    var onPointer: (UInt32, Double, Double, Double, Double, Int32, Int32) -> Void
    var onKey: (Bool, Int32, Int32, UInt32) -> Void
    /// True while the focused game layer accepts composed text; keys then go
    /// through the input method instead of the raw key path.
    var imeActiveProvider: () -> Bool = { false }
    /// (markedText, cursor range) during composition; empty text ends it.
    var onComposeIME: (String, NSRange) -> Void = { _, _ in }
    /// Committed text (direct typing, paste or IME commit) for TEXT_INPUT.
    var onCommitText: (String) -> Void = { _ in }
    /// Engine canvas point of the focused caret; the view maps it to the
    /// candidate-window rect so geometry stays in one place.
    var caretCanvasPointProvider: () -> CGPoint? = { nil }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InputNSView {
        let view = InputNSView()
        view.contentSize = contentSize
        view.onPointer = onPointer
        view.onKey = onKey
        apply(to: view)
        context.coordinator.install(hostView: view)
        return view
    }

    func updateNSView(_ nsView: InputNSView, context: Context) {
        nsView.contentSize = contentSize
        nsView.onPointer = onPointer
        nsView.onKey = onKey
        apply(to: nsView)
    }

    private func apply(to view: InputNSView) {
        view.imeActiveProvider = imeActiveProvider
        view.onComposeIME = onComposeIME
        view.onCommitText = onCommitText
        view.caretCanvasPointProvider = caretCanvasPointProvider
    }

    static func dismantleNSView(_ nsView: InputNSView, coordinator: Coordinator) {
        coordinator.uninstall()
        nsView.cancelPressedButtons()
        if InputNSView.activeView === nsView {
            InputNSView.activeView = nil
        }
    }

    final class Coordinator {
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var deactivateObserver: NSObjectProtocol?

        func install(hostView: InputNSView) {
            InputNSView.activeView = hostView
            guard monitor == nil else { return }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil,
                queue: .main
            ) { [weak hostView] notification in
                guard let view = hostView,
                      let window = notification.object as? NSWindow,
                      window === view.window else { return }
                view.cancelPressedButtons()
            }
            deactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak hostView] _ in hostView?.cancelPressedButtons() }
            let mask: NSEvent.EventTypeMask = [
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                .mouseMoved, .scrollWheel, .keyDown, .keyUp,
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
                [weak hostView] event in
                guard let view = hostView,
                      let window = view.window,
                      event.window === window else {
                    return event
                }
                return view.handle(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
            resignObserver = nil
            if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
            deactivateObserver = nil
        }
    }
}

final class InputNSView: NSView {
    static weak var activeView: InputNSView?

    var contentSize: CGSize = .zero
    var onPointer: ((UInt32, Double, Double, Double, Double, Int32, Int32) -> Void)?
    var onKey: ((Bool, Int32, Int32, UInt32) -> Void)?
    var imeActiveProvider: (() -> Bool)?
    var onComposeIME: ((String, NSRange) -> Void)?
    var onCommitText: ((String) -> Void)?
    var caretCanvasPointProvider: (() -> CGPoint?)?

    private var pressedButtons: Set<Int32> = []
    private var pressedKeys: Set<Int32> = []
    private var lastPointerPoint: CGPoint = .zero
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var pendingKeyEvent: NSEvent?

    var imeEnabled: Bool { imeActiveProvider?() == true }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool {
        cancelPressedButtons()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        // Keyboard input should work without requiring a click first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    // Returns true when the event is consumed by the game surface.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard mappedPoint(event) != nil else { return false }
            pressedButtons.insert(button(for: event))
            window?.makeFirstResponder(self)
            sendPointer(
                EngineInputEvent.pointerDown, event,
                button: button(for: event))
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard pressedButtons.remove(button(for: event)) != nil else { return false }
            sendPointer(
                EngineInputEvent.pointerUp, event,
                button: button(for: event))
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard pressedButtons.contains(button(for: event)) else { return false }
            sendPointer(
                EngineInputEvent.pointerMove, event,
                button: button(for: event))
            return true
        case .mouseMoved:
            guard mappedPoint(event) != nil else { return false }
            sendPointer(EngineInputEvent.pointerMove, event, button: 0)
            return true
        case .scrollWheel:
            guard mappedPoint(event) != nil else { return false }
            sendPointer(
                EngineInputEvent.pointerScroll, event, button: 0,
                scrollDeltaY: Double(event.scrollingDeltaY))
            return true
        case .keyDown:
            // Only capture keys while the game surface owns the first
            // responder; typing in toolbar fields keeps its field editor.
            guard window?.firstResponder === self,
                  !event.modifierFlags.contains(.command) else { return false }
            if imeEnabled {
                // A focused game edit control owns the input method: compose
                // through AppKit and deliver text/commands from its callbacks.
                pendingKeyEvent = event
                interpretKeyEvents([event])
                pendingKeyEvent = nil
                return true
            }
            let keyCode = InputMapping.virtualKey(event)
            guard keyCode != 0 else { return false }
            pressedKeys.insert(keyCode)
            onKey?(
                true, keyCode, InputMapping.modifiers(event),
                InputMapping.unicodeScalar(event))
            return true
        case .keyUp:
            let keyCode = InputMapping.virtualKey(event)
            guard pressedKeys.remove(keyCode) != nil else { return false }
            onKey?(false, keyCode, InputMapping.modifiers(event), 0)
            return true
        default:
            return false
        }
    }

    func cancelPressedButtons() {
        cancelComposition()
        for button in pressedButtons {
            onPointer?(EngineInputEvent.pointerUp,
                       Double(lastPointerPoint.x), Double(lastPointerPoint.y),
                       0, 0, button, Int32(1 << 30))
        }
        pressedButtons.removeAll()
        for key in pressedKeys.sorted() { onKey?(false, key, 0, 0) }
        pressedKeys.removeAll()
    }

    /// Ends in-progress composition (window resign, teardown, focus loss) so
    /// the engine never keeps a stale preedit.
    func cancelComposition() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        onComposeIME?("", NSRange(location: 0, length: 0))
    }

    /// Mirrors the Godot macOS window, which is a text input client: while a
    /// game edit control is focused, Paste (⌘V) commits the pasteboard text.
    /// `paste:` is not declared by NSView, so this is a plain action method
    /// reached through the responder chain.
    @objc func paste(_ sender: Any?) {
        guard imeEnabled, window?.firstResponder === self,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        onCommitText?(text)
    }

    private func button(for event: NSEvent) -> Int32 {
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: return 2
        default: return 0
        }
    }

    // View-space point with top-left origin (matches the SwiftUI image rect).
    private func viewPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func mappedPoint(_ event: NSEvent) -> CGPoint? {
        InputMapping.mapToSurface(
            point: viewPoint(event),
            viewSize: bounds.size,
            contentSize: contentSize)
    }

    private func sendPointer(
        _ type: UInt32, _ event: NSEvent, button: Int32,
        scrollDeltaY: Double = 0
    ) {
        // Preserve a captured drag/release outside the canvas so the engine
        // never keeps a button pressed after the pointer leaves the view.
        guard let mapped = mappedPoint(event)
            ?? (pressedButtons.isEmpty && type != EngineInputEvent.pointerUp
                ? nil : lastPointerPoint) else { return }
        lastPointerPoint = mapped
        onPointer?(
            type,
            Double(mapped.x),
            Double(mapped.y),
            0,
            scrollDeltaY,
            button,
            InputMapping.modifiers(event))
    }

    /// Command keys still have to reach the game while composition owns the
    /// keyboard; selectors outside the map fall back to the raw key path so
    /// nothing is dropped silently.
    override func doCommand(by selector: Selector) {
        if let keyCode = IMECommandMap.virtualKey(for: selector) {
            onKey?(true, keyCode, 0, 0)
            onKey?(false, keyCode, 0, 0)
            return
        }
        if let event = pendingKeyEvent {
            let keyCode = InputMapping.virtualKey(event)
            guard keyCode != 0 else {
                super.doCommand(by: selector)
                return
            }
            onKey?(true, keyCode, InputMapping.modifiers(event),
                   InputMapping.unicodeScalar(event))
            onKey?(false, keyCode, InputMapping.modifiers(event), 0)
            return
        }
        super.doCommand(by: selector)
    }
}

// MARK: - Composed text (IME)
//
// While a game edit control is focused this view is AppKit's text input
// client: composition is forwarded through the engine preedit options, commits
// become TEXT_INPUT, and the candidate window follows the game caret. The game
// owns the document, so reported ranges cover the local composition buffer.
extension InputNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainText(string)
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        onComposeIME?("", NSRange(location: 0, length: 0))
        guard !text.isEmpty else { return }
        onCommitText?(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainText(string)
        markedText = text
        markedSelection = selectedRange
        onComposeIME?(text, selectedRange)
    }

    func unmarkText() {
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        onComposeIME?("", NSRange(location: 0, length: 0))
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func selectedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: 0, length: 0) : markedSelection
    }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let point = caretCanvasPointProvider?(),
              let topLeft = GameTextCaret.rect(
                canvasPoint: point, viewSize: bounds.size, contentSize: contentSize),
              let window else {
            return .zero
        }
        // NSView is bottom-left oriented; GameTextCaret works in top-left space.
        let flipped = NSRect(
            x: topLeft.minX, y: bounds.height - topLeft.maxY,
            width: max(1, topLeft.width), height: topLeft.height)
        return window.convertToScreen(convert(flipped, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private static func plainText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return ""
    }
}
