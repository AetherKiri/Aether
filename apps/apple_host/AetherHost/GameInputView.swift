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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InputNSView {
        let view = InputNSView()
        view.contentSize = contentSize
        view.onPointer = onPointer
        view.onKey = onKey
        context.coordinator.install(hostView: view)
        return view
    }

    func updateNSView(_ nsView: InputNSView, context: Context) {
        nsView.contentSize = contentSize
        nsView.onPointer = onPointer
        nsView.onKey = onKey
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

    private var pressedButtons: Set<Int32> = []
    private var pressedKeys: Set<Int32> = []
    private var lastPointerPoint: CGPoint = .zero

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
        for button in pressedButtons {
            onPointer?(EngineInputEvent.pointerUp,
                       Double(lastPointerPoint.x), Double(lastPointerPoint.y),
                       0, 0, button, Int32(1 << 30))
        }
        pressedButtons.removeAll()
        for key in pressedKeys.sorted() { onKey?(false, key, 0, 0) }
        pressedKeys.removeAll()
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
}
