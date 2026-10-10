import AppKit
import SwiftUI

// Transparent event-capture view layered over the game frame. Converts
// AppKit events into engine input (view space -> canvas space) and forwards
// them through closures; see InputMapping for the translation contract.
struct GameInputView: NSViewRepresentable {
    var contentSize: CGSize
    var onPointer: (UInt32, Double, Double, Double, Double, Int32, Int32) -> Void
    var onKey: (Bool, Int32, Int32, UInt32) -> Void

    func makeNSView(context: Context) -> InputNSView {
        let view = InputNSView()
        view.contentSize = contentSize
        view.onPointer = onPointer
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: InputNSView, context: Context) {
        nsView.contentSize = contentSize
        nsView.onPointer = onPointer
        nsView.onKey = onKey
    }
}

final class InputNSView: NSView {
    var contentSize: CGSize = .zero
    var onPointer: ((UInt32, Double, Double, Double, Double, Int32, Int32) -> Void)?
    var onKey: ((Bool, Int32, Int32, UInt32) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keyboard input should work without requiring a click first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
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
        _ type: UInt32, _ event: NSEvent, button: Int32, scrollDeltaY: Double = 0
    ) {
        guard let mapped = mappedPoint(event) else { return }
        onPointer?(
            type,
            Double(mapped.x),
            Double(mapped.y),
            0,
            scrollDeltaY,
            button,
            InputMapping.modifiers(event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(EngineInputEvent.pointerDown, event, button: 0)
    }
    override func mouseUp(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerUp, event, button: 0)
    }
    override func mouseMoved(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerMove, event, button: 0)
    }
    override func mouseDragged(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerMove, event, button: 0)
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(EngineInputEvent.pointerDown, event, button: 1)
    }
    override func rightMouseUp(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerUp, event, button: 1)
    }
    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerMove, event, button: 1)
    }
    override func otherMouseDown(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerDown, event, button: 2)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerUp, event, button: 2)
    }
    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(EngineInputEvent.pointerMove, event, button: 2)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let mapped = mappedPoint(event) else { return }
        onPointer?(
            EngineInputEvent.pointerScroll,
            Double(mapped.x),
            Double(mapped.y),
            0,
            Double(event.scrollingDeltaY),
            0,
            InputMapping.modifiers(event))
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = InputMapping.virtualKey(event)
        guard keyCode != 0 else {
            super.keyDown(with: event)
            return
        }
        onKey?(
            true,
            keyCode,
            InputMapping.modifiers(event),
            InputMapping.unicodeScalar(event))
    }

    override func keyUp(with event: NSEvent) {
        let keyCode = InputMapping.virtualKey(event)
        guard keyCode != 0 else {
            super.keyUp(with: event)
            return
        }
        onKey?(false, keyCode, InputMapping.modifiers(event), 0)
    }
}
