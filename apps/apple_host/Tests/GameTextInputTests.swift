import AppKit
import Foundation

@main
struct GameTextInputTests {
    static func main() {
        // State parsing mirrors the Godot player's get_text_input_state().
        let idle = GameTextInputState()
        precondition(!idle.available && !idle.wantsHostIME)
        let unavailable = GameTextInputState(dictionary: ["available": NSNumber(value: 0)])
        precondition(!unavailable.available)

        let editing = GameTextInputState(dictionary: [
            "available": NSNumber(value: 1),
            "imeActive": NSNumber(value: 1),
            "imeMode": NSNumber(value: 3),
            "attentionValid": NSNumber(value: 1),
            "attentionX": NSNumber(value: 120),
            "attentionY": NSNumber(value: 240),
            "textAvailable": NSNumber(value: 1),
            "textBytes": NSNumber(value: 5),
            "selectionStart": NSNumber(value: 1),
            "selectionEnd": NSNumber(value: 3),
        ])
        precondition(editing.available && editing.imeActive)
        precondition(editing.imeMode == 3)
        precondition(editing.attentionValid && editing.attention == CGPoint(x: 120, y: 240))
        precondition(editing.textAvailable && editing.textBytes == 5)
        precondition(editing.selectionStart == 1 && editing.selectionLength == 2)
        precondition(editing.wantsHostIME)

        // Activation requires a caret and an IME-capable layer, matching the
        // Godot shell's should_activate decision.
        var noCaret = editing
        noCaret.attentionValid = false
        precondition(!noCaret.wantsHostIME)
        var imeOff = editing
        imeOff.imeActive = false
        precondition(!imeOff.wantsHostIME)
        var noEngine = editing
        noEngine.available = false
        precondition(!noEngine.wantsHostIME)
        // Selection is reported as a length, never negative.
        var reversed = editing
        reversed.selectionStart = 7
        reversed.selectionEnd = 2
        precondition(reversed.selectionLength == 0)

        // Composition tracking: forward changes once, dedupe repeats, clear.
        var tracker = IMEPreeditTracker()
        precondition(tracker.update(markedText: "", selectedRange: NSRange(location: 0, length: 0)) == nil)
        let first = tracker.update(markedText: "ni", selectedRange: NSRange(location: 2, length: 0))
        precondition(first == IMEPreedit(text: "ni", cursorStart: 2, cursorLength: 0))
        precondition(tracker.update(markedText: "ni", selectedRange: NSRange(location: 2, length: 0)) == nil)
        let second = tracker.update(markedText: "你好", selectedRange: NSRange(location: 0, length: 1))
        precondition(second == IMEPreedit(text: "你好", cursorStart: 0, cursorLength: 1))
        let cleared = tracker.update(markedText: "", selectedRange: NSRange(location: 0, length: 0))
        precondition(cleared == IMEPreedit.cleared)
        precondition(tracker.update(markedText: "", selectedRange: NSRange(location: 0, length: 0)) == nil)
        // Out-of-range selections are clamped into the composition buffer.
        let clamped = tracker.update(markedText: "ab", selectedRange: NSRange(location: 9, length: 9))
        precondition(clamped == IMEPreedit(text: "ab", cursorStart: 2, cursorLength: 0))
        tracker.reset()
        precondition(tracker.sent == nil)

        // Command selectors that still reach the game while composing.
        let expected: [(Selector, Int32)] = [
            (#selector(NSResponder.insertNewline(_:)), 0x0D),
            (#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), 0x0D),
            (#selector(NSResponder.cancelOperation(_:)), 0x1B),
            (#selector(NSResponder.deleteBackward(_:)), 0x08),
            (#selector(NSResponder.deleteForward(_:)), 0x2E),
            (#selector(NSResponder.insertTab(_:)), 0x09),
            (#selector(NSResponder.moveLeft(_:)), 0x25),
            (#selector(NSResponder.moveUp(_:)), 0x26),
            (#selector(NSResponder.moveRight(_:)), 0x27),
            (#selector(NSResponder.moveDown(_:)), 0x28),
            (#selector(NSResponder.moveToBeginningOfLine(_:)), 0x24),
            (#selector(NSResponder.moveToEndOfLine(_:)), 0x23),
            (#selector(NSResponder.pageUp(_:)), 0x21),
            (#selector(NSResponder.pageDown(_:)), 0x22),
        ]
        for (selector, key) in expected {
            precondition(IMECommandMap.virtualKey(for: selector) == key, "\(selector)")
        }
        precondition(IMECommandMap.virtualKey(for: #selector(NSResponder.selectAll(_:))) == nil)

        // Caret rect: canvas -> view (top-left) with the same aspect-fit rule
        // as pointer mapping, so the candidate window follows the game caret.
        let viewSize = CGSize(width: 800, height: 600)
        let content = CGSize(width: 640, height: 480)
        // 800/640 = 1.25 and 600/480 = 1.25 -> exact fit, no letterbox.
        let centered = GameTextCaret.rect(
            canvasPoint: CGPoint(x: 320, y: 240), viewSize: viewSize, contentSize: content)
        precondition(centered?.minX == 400 && centered?.minY == 300, "\(String(describing: centered))")
        // Tall view: drawn canvas is 800x600 centred in 800x900 -> y offset 150.
        let letterboxed = GameTextCaret.rect(
            canvasPoint: CGPoint(x: 0, y: 0), viewSize: CGSize(width: 800, height: 900),
            contentSize: content)
        precondition(letterboxed?.minX == 0 && letterboxed?.minY == 150, "\(String(describing: letterboxed))")
        // Narrow view: scale 0.9375 -> drawn 600x450 with a 75 point y offset.
        let narrow = GameTextCaret.rect(
            canvasPoint: CGPoint(x: 640, y: 480), viewSize: CGSize(width: 600, height: 600),
            contentSize: content)
        precondition(narrow?.minX == 600 && narrow?.minY == 525, "\(String(describing: narrow))")
        // A caret outside the canvas clamps to the drawn edge.
        let clampedCaret = GameTextCaret.rect(
            canvasPoint: CGPoint(x: 9999, y: 9999), viewSize: viewSize, contentSize: content)
        precondition(clampedCaret?.minX == 800 && clampedCaret?.minY == 600,
                     "\(String(describing: clampedCaret))")
        precondition(GameTextCaret.rect(
            canvasPoint: .zero, viewSize: .zero, contentSize: content) == nil)
        precondition(InputMapping.mapCanvasToView(
            point: .zero, viewSize: viewSize, contentSize: .zero) == nil)

        print("PASS: text input state, IME activation, preedit tracking, command map and caret geometry")
    }
}
