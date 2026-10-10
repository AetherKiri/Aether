import AppKit

@main
struct InputTests {
    static func main() {
        let application = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = InputNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.contentSize = CGSize(width: 640, height: 480)
        window.contentView = view
        window.makeFirstResponder(view)
        var pointers: [(UInt32, Double, Double, Int32)] = []
        var keys: [(Bool, Int32)] = []
        view.onPointer = { type, x, y, _, _, _, modifiers in
            pointers.append((type, x, y, modifiers))
        }
        view.onKey = { pressed, key, _, _ in keys.append((pressed, key)) }
        func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y),
                               modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // An 800x480 view has 80-point side bars around a 640x480 game.
        precondition(!view.handle(mouse(.leftMouseDown, 20, 240)))
        precondition(pointers.isEmpty, "letterbox clicks must pass through")
        precondition(view.handle(mouse(.leftMouseDown, 400, 240)))
        precondition(pointers[0].1 == 320 && pointers[0].2 == 240)
        precondition(view.handle(mouse(.leftMouseDragged, 900, 240)))
        precondition(view.handle(mouse(.leftMouseUp, 900, 240)))
        precondition(pointers.last!.0 == EngineInputEvent.pointerUp)
        precondition(!view.handle(mouse(.leftMouseUp, 400, 240)), "no unmatched releases")
        precondition(view.handle(mouse(.leftMouseDown, 400, 240)))
        view.cancelPressedButtons()
        precondition(pointers.last!.3 == Int32(1 << 30), "focus loss cancels captured presses")
        func key(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: "a", charactersIgnoringModifiers: "a",
                             isARepeat: false, keyCode: 0)!
        }
        precondition(!view.handle(key(.command)), "app shortcuts must pass through")
        precondition(view.handle(key([])))
        precondition(keys.count == 1 && keys[0].0 && keys[0].1 == 0x41)
        let field = NSTextView(frame: .zero)
        view.addSubview(field)
        window.makeFirstResponder(field)
        precondition(keys.count == 2 && !keys[1].0 && keys[1].1 == 0x41, "focus loss releases keys")
        precondition(!view.handle(key([])), "text editor keeps its keyboard input")
        let coordinator = GameInputView.Coordinator()
        coordinator.install(hostView: view)
        window.makeFirstResponder(view)
        precondition(view.handle(key([])))
        precondition(view.handle(mouse(.leftMouseDown, 400, 240)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(pointers.last!.3 == Int32(1 << 30), "window deactivation cancels input")
        precondition(keys.count == 4 && !keys[3].0, "window deactivation releases keyboard")
        view.cancelPressedButtons()
        precondition(keys.count == 4, "cancellation is idempotent")
        precondition(view.handle(key([])))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: application)
        precondition(keys.count == 6 && !keys[5].0, "application deactivation releases keyboard")
        GameInputView.dismantleNSView(view, coordinator: coordinator)
        precondition(InputNSView.activeView == nil, "dismantle clears the active view")
        _ = application
        print("PASS: letterbox, mapping, outside release, cancellation, shortcut, field focus, teardown")
    }
}
