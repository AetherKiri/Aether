import AppKit
import Foundation

/// Snapshot of the focused KiriKiri text layer (engine_text_input_state_t),
/// mirroring the Godot shell's get_text_input_state().
struct GameTextInputState: Equatable {
    var available = false
    var imeActive = false
    var imeMode: Int32 = 0
    var attentionValid = false
    var attention: CGPoint = .zero
    var textAvailable = false
    var textBytes = 0
    var selectionStart: Int32 = 0
    var selectionEnd: Int32 = 0

    /// Composed input is enabled only when the focused layer publishes a caret
    /// and accepts IME input — the same decision the Godot shell makes before
    /// calling window_set_ime_active().
    var wantsHostIME: Bool { available && attentionValid && imeActive }
    var selectionLength: Int32 { max(0, selectionEnd - selectionStart) }

    init() {}

    init(dictionary: [String: NSNumber]) {
        available = dictionary["available"]?.boolValue ?? false
        imeActive = dictionary["imeActive"]?.boolValue ?? false
        imeMode = dictionary["imeMode"]?.int32Value ?? 0
        attentionValid = dictionary["attentionValid"]?.boolValue ?? false
        attention = CGPoint(
            x: dictionary["attentionX"]?.doubleValue ?? 0,
            y: dictionary["attentionY"]?.doubleValue ?? 0)
        textAvailable = dictionary["textAvailable"]?.boolValue ?? false
        textBytes = dictionary["textBytes"]?.intValue ?? 0
        selectionStart = dictionary["selectionStart"]?.int32Value ?? 0
        selectionEnd = dictionary["selectionEnd"]?.int32Value ?? 0
    }
}

/// IME composition payload forwarded through the "ime_preedit_cursor" /
/// "ime_preedit" engine options (see the Godot player's send_ime_preedit()).
struct IMEPreedit: Equatable {
    var text: String
    var cursorStart: Int
    var cursorLength: Int

    static let cleared = IMEPreedit(text: "", cursorStart: 0, cursorLength: 0)
}

/// Tracks the composition buffer and the payload last handed to the engine so
/// unchanged marked text does not rewrite engine options on every keystroke.
struct IMEPreeditTracker {
    private(set) var sent: IMEPreedit?

    /// Returns the payload to forward, or nil when nothing changed.
    mutating func update(markedText: String, selectedRange: NSRange) -> IMEPreedit? {
        guard !markedText.isEmpty else { return clearIfNeeded() }
        let length = (markedText as NSString).length
        let start = max(0, min(selectedRange.location, length))
        let selected = max(0, min(selectedRange.length, length - start))
        let payload = IMEPreedit(text: markedText, cursorStart: start, cursorLength: selected)
        guard payload != sent else { return nil }
        sent = payload
        return payload
    }

    /// Returns the payload that clears a previously forwarded preedit; nil when
    /// the engine already has an empty preedit.
    mutating func clearIfNeeded() -> IMEPreedit? {
        guard sent != nil, sent != IMEPreedit.cleared else { return nil }
        sent = IMEPreedit.cleared
        return IMEPreedit.cleared
    }

    /// Drops local bookkeeping without contacting the engine (shutdown path).
    mutating func reset() { sent = nil }
}

/// AppKit command selectors that must still reach the game as key events while
/// a game text field owns composed input (the raw key path is bypassed then).
enum IMECommandMap {
    static func virtualKey(for selector: Selector) -> Int32? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return 0x0D
        case #selector(NSResponder.cancelOperation(_:)):
            return 0x1B
        case #selector(NSResponder.deleteBackward(_:)):
            return 0x08
        case #selector(NSResponder.deleteForward(_:)):
            return 0x2E
        case #selector(NSResponder.insertTab(_:)):
            return 0x09
        case #selector(NSResponder.moveLeft(_:)):
            return 0x25
        case #selector(NSResponder.moveUp(_:)):
            return 0x26
        case #selector(NSResponder.moveRight(_:)):
            return 0x27
        case #selector(NSResponder.moveDown(_:)):
            return 0x28
        case #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            return 0x24
        case #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)):
            return 0x23
        case #selector(NSResponder.pageUp(_:)):
            return 0x21
        case #selector(NSResponder.pageDown(_:)):
            return 0x22
        default:
            return nil
        }
    }
}

/// Caret geometry for the IME candidate window and for host diagnostics.
enum GameTextCaret {
    static let defaultHeight: CGFloat = 20

    /// View-space rect (top-left origin) anchored at the engine attention
    /// point. Nil while the canvas is not laid out.
    static func rect(
        canvasPoint: CGPoint, viewSize: CGSize, contentSize: CGSize,
        height: CGFloat = defaultHeight
    ) -> CGRect? {
        guard let origin = InputMapping.mapCanvasToView(
            point: canvasPoint, viewSize: viewSize, contentSize: contentSize) else {
            return nil
        }
        return CGRect(x: origin.x, y: origin.y, width: 1, height: height)
    }
}
