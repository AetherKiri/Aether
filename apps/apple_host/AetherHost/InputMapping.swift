import AppKit
import Carbon.HIToolbox
import CoreGraphics

// macOS -> engine input translation.
//
// The engine uses Windows VK key codes and bitmap-surface coordinates; both
// contracts mirror the Godot host (apps/godot_app/scripts/main.gd
// `_kirikiri_virtual_key` and game_input_mapping.gd `map_point`).

// engine_input_event_type_t
enum EngineInputEvent {
    static let pointerDown: UInt32 = 1
    static let pointerMove: UInt32 = 2
    static let pointerUp: UInt32 = 3
    static let pointerScroll: UInt32 = 4
    static let keyDown: UInt32 = 5
    static let keyUp: UInt32 = 6
    static let textInput: UInt32 = 7
}

enum InputMapping {

    // macOS virtual key code -> Windows VK code (engine convention).
    static func virtualKey(_ event: NSEvent) -> Int32 {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return 0x0D
        case kVK_Escape: return 0x1B
        case kVK_Space: return 0x20
        case kVK_Delete: return 0x08
        case kVK_ForwardDelete: return 0x2E
        case kVK_Tab: return 0x09
        case kVK_LeftArrow: return 0x25
        case kVK_UpArrow: return 0x26
        case kVK_RightArrow: return 0x27
        case kVK_DownArrow: return 0x28
        case kVK_Home: return 0x24
        case kVK_End: return 0x23
        case kVK_PageUp: return 0x21
        case kVK_PageDown: return 0x22
        case kVK_Help: return 0x2D
        case kVK_F1: return 0x70
        case kVK_F2: return 0x71
        case kVK_F3: return 0x72
        case kVK_F4: return 0x73
        case kVK_F5: return 0x74
        case kVK_F6: return 0x75
        case kVK_F7: return 0x76
        case kVK_F8: return 0x77
        case kVK_F9: return 0x78
        case kVK_F10: return 0x79
        case kVK_F11: return 0x7A
        case kVK_F12: return 0x7B
        default:
            break
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return 0
        }
        let value = Int32(scalar.value)
        if value >= 0x61 && value <= 0x7A { return value - 0x20 }  // a-z -> VK A-Z
        if value >= 0x41 && value <= 0x5A { return value }
        if value >= 0x30 && value <= 0x39 { return value }
        if value > 0 && value <= 0xFF { return value }
        return 0
    }

    // 0x01 shift / 0x02 alt / 0x04 ctrl / 0x80 key-repeat echo.
    static func modifiers(_ event: NSEvent) -> Int32 {
        var modifiers: Int32 = 0
        if event.modifierFlags.contains(.shift) { modifiers |= 0x01 }
        if event.modifierFlags.contains(.option) { modifiers |= 0x02 }
        if event.modifierFlags.contains(.control) { modifiers |= 0x04 }
        if event.type == .keyDown && event.isARepeat { modifiers |= 0x80 }
        return modifiers
    }

    // Printable unicode scalar for the engine TEXT_INPUT companion event.
    static func unicodeScalar(_ event: NSEvent) -> UInt32 {
        guard let scalar = event.characters?.unicodeScalars.first else { return 0 }
        let value = scalar.value
        if value < 0x20 || value == 0x7F { return 0 }
        return value
    }

    // Aspect-fit mapping from view space (top-left origin) to engine canvas.
    // Mirrors GameInputMapping.map_point with surface == content for now.
    static func mapToSurface(
        point: CGPoint, viewSize: CGSize, contentSize: CGSize
    ) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else {
            return nil
        }
        let scale = min(
            viewSize.width / contentSize.width,
            viewSize.height / contentSize.height)
        guard scale > 0 else { return nil }
        let drawn = CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale)
        let origin = CGPoint(
            x: (viewSize.width - drawn.width) / 2,
            y: (viewSize.height - drawn.height) / 2)
        let inside = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard inside.x >= 0, inside.y >= 0,
              inside.x <= drawn.width, inside.y <= drawn.height else {
            return nil
        }
        return CGPoint(x: inside.x / scale, y: inside.y / scale)
    }
}
