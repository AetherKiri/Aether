#pragma once

namespace aetherkiri::renpy::input_mapping {

// The Godot shell translates keys to Windows-style virtual keys and uses
// KiriKiri modifier bits (main.gd's _kirikiri_virtual_key/key_modifiers).
// Ren'Py 8.5.x uses pygame_sdl2's SDL2 keycodes/KMOD_* values. Keep this
// translation independent of SDL headers, which are owned by the child SDK.
constexpr int kPygameScancodeMask = 1 << 30;
constexpr int kPygameKmodShift = 0x0003;
constexpr int kPygameKmodControl = 0x00c0;
constexpr int kPygameKmodAlt = 0x0300;
constexpr int kPygameKmodGui = 0x0c00;
constexpr int kAetherModifierShift = 0x01;
constexpr int kAetherModifierAlt = 0x02;
constexpr int kAetherModifierControl = 0x04;
constexpr int kAetherModifierEcho = 0x80;
constexpr int kGodotModifierShift = 1 << 25;
constexpr int kGodotModifierAlt = 1 << 26;
constexpr int kGodotModifierMeta = 1 << 27;
constexpr int kGodotModifierControl = 1 << 28;
constexpr int kGodotSpecial = 1 << 22;
constexpr int kGodotCodeMask = 0x007fffff;

constexpr inline int PygameFunctionKey(int function) {
    // SDL2's F1-F12 scancodes are contiguous at 58. F13-F24 start at
    // scancode 104, after the keypad block.
    if (function >= 1 && function <= 12)
        return kPygameScancodeMask + 58 + function - 1;
    if (function >= 13 && function <= 24)
        return kPygameScancodeMask + 104 + function - 13;
    return 0;
}

inline int MapPointerButtonToPygame(int button) {
    // EngineApi: 0=left, 1=right, 2=middle. pygame: 1=left, 2=middle,
    // 3=right. Do not confuse the already-translated ABI with raw Godot's
    // MouseButton enum (1=left, 2=right, 3=middle).
    switch (button) {
    case 0: return 1;
    case 1: return 3;
    case 2: return 2;
    default: return button > 0 ? button : 1;
    }
}

// Ren'Py-only use of engine_input_event_t.reserved_u32. An explicit source
// removes the low-byte ambiguity between Godot characters and Windows VKs.
// The provider consumes this field before sending SDL keycodes to the launcher.
enum class KeyCodeSpace : unsigned int { Legacy = 0, Godot = 1 };

inline int MapGodotKeyCodeToPygame(int code) {
    code &= kGodotCodeMask;
    if (code >= kGodotSpecial && code < kGodotSpecial + 0x1000) {
        const int special = code - kGodotSpecial;
        switch (special) {
        case 1:  return 27;                       // Escape
        case 2:  // Tab
        case 3:  return 9;                        // Backtab
        case 4:  return 8;                        // Backspace
        case 5:  return 13;                       // Return
        case 6:  return kPygameScancodeMask + 88;  // Keypad Enter
        case 7:  return kPygameScancodeMask + 73;  // Insert
        case 8:  return 127;                      // Delete
        case 9:  return kPygameScancodeMask + 72;  // Pause/Break
        case 10: return kPygameScancodeMask + 70;  // Print Screen
        case 11: return kPygameScancodeMask + 154; // SysReq
        case 12: return kPygameScancodeMask + 156; // Clear
        case 13: return kPygameScancodeMask + 74;  // Home
        case 14: return kPygameScancodeMask + 77;  // End
        case 15: return kPygameScancodeMask + 80;  // Left
        case 16: return kPygameScancodeMask + 82;  // Up
        case 17: return kPygameScancodeMask + 79;  // Right
        case 18: return kPygameScancodeMask + 81;  // Down
        case 19: return kPygameScancodeMask + 75;  // Page Up
        case 20: return kPygameScancodeMask + 78;  // Page Down
        case 21: return kPygameScancodeMask + 225; // Shift (left)
        case 22: return kPygameScancodeMask + 224; // Ctrl (left)
        case 23: return kPygameScancodeMask + 227; // Meta (left)
        case 24: return kPygameScancodeMask + 226; // Alt (left)
        case 25: return kPygameScancodeMask + 57;  // Caps Lock
        case 26: return kPygameScancodeMask + 83;  // Num Lock
        case 27: return kPygameScancodeMask + 71;  // Scroll Lock
        case 66: return kPygameScancodeMask + 118; // Menu
        case 69: return kPygameScancodeMask + 117; // Help
        default: break;
        }
        if (special >= 28 && special <= 62)
            return PygameFunctionKey(special - 27); // F1-F35 (SDL has F1-F24)
        if (special >= 129 && special <= 143) {
            static constexpr int keypad[] = {
                85, 84, 86, 99, 87, 98, 89, 90,
                91, 92, 93, 94, 95, 96, 97,
            }; // Multiply, divide, subtract, period, add, 0..9.
            return kPygameScancodeMask + keypad[special - 129];
        }
        return 0;
    }

    if (code >= 'A' && code <= 'Z') return code + ('a' - 'A');
    if (code >= 0x20 && code <= 0x10ffff &&
        !(code >= 0xd800 && code <= 0xdfff)) return code;
    return 0;
}

inline int MapKeyCodeToPygame(int code, KeyCodeSpace space = KeyCodeSpace::Legacy) {
    if (space == KeyCodeSpace::Godot) return MapGodotKeyCodeToPygame(code);
    // Preserve SDL2 non-printable keycodes used by existing direct callers.
    // Low-byte SDL ASCII and Windows VK values overlap; the ABI's VK
    // interpretation takes precedence (e.g. 0x70 means F1, not 'p').
    if (code >= kPygameScancodeMask) return code;
    if (code >= 0x01000000) code &= kGodotCodeMask;

    // Raw Godot special keys remain accepted by legacy direct callers.
    if (code >= kGodotSpecial && code < kGodotSpecial + 0x1000)
        return MapGodotKeyCodeToPygame(code);

    switch (code) {
    case 0x08: return 8;                          // Backspace
    case 0x09: return 9;                          // Tab
    case 0x0c: return kPygameScancodeMask + 156;  // Clear
    case 0x0d: return 13;                         // Return
    case 0x10: return kPygameScancodeMask + 225;  // Shift
    case 0x11: return kPygameScancodeMask + 224;  // Ctrl
    case 0x12: return kPygameScancodeMask + 226;  // Alt
    case 0x13: return kPygameScancodeMask + 72;   // Pause
    case 0x14: return kPygameScancodeMask + 57;   // Caps Lock
    case 0x1b: return 27;                         // Escape
    case 0x20: return 32;                         // Space
    case 0x21: return kPygameScancodeMask + 75;   // Page Up
    case 0x22: return kPygameScancodeMask + 78;   // Page Down
    case 0x23: return kPygameScancodeMask + 77;   // End
    case 0x24: return kPygameScancodeMask + 74;   // Home
    case 0x25: return kPygameScancodeMask + 80;   // Left
    case 0x26: return kPygameScancodeMask + 82;   // Up
    case 0x27: return kPygameScancodeMask + 79;   // Right
    case 0x28: return kPygameScancodeMask + 81;   // Down
    case 0x2c: return kPygameScancodeMask + 70;   // Print Screen
    case 0x2d: return kPygameScancodeMask + 73;   // Insert
    case 0x2e: return 127;                        // Delete
    case 0x2f: return kPygameScancodeMask + 117;  // Help
    case 0x5b: return kPygameScancodeMask + 227;  // Left Windows
    case 0x5c: return kPygameScancodeMask + 231;  // Right Windows
    case 0x5d: return kPygameScancodeMask + 101;  // Applications
    case 0x6a: return kPygameScancodeMask + 85;   // Keypad multiply
    case 0x6b: return kPygameScancodeMask + 87;   // Keypad add
    case 0x6c: return kPygameScancodeMask + 133;  // Keypad separator
    case 0x6d: return kPygameScancodeMask + 86;   // Keypad subtract
    case 0x6e: return kPygameScancodeMask + 99;   // Keypad decimal
    case 0x6f: return kPygameScancodeMask + 84;   // Keypad divide
    case 0x90: return kPygameScancodeMask + 83;   // Num Lock
    case 0x91: return kPygameScancodeMask + 71;   // Scroll Lock
    case 0xa0: return kPygameScancodeMask + 225;  // Left Shift
    case 0xa1: return kPygameScancodeMask + 229;  // Right Shift
    case 0xa2: return kPygameScancodeMask + 224;  // Left Ctrl
    case 0xa3: return kPygameScancodeMask + 228;  // Right Ctrl
    case 0xa4: return kPygameScancodeMask + 226;  // Left Alt
    case 0xa5: return kPygameScancodeMask + 230;  // Right Alt
    case 0xba: return ';';
    case 0xbb: return '=';
    case 0xbc: return ',';
    case 0xbd: return '-';
    case 0xbe: return '.';
    case 0xbf: return '/';
    case 0xc0: return '`';
    case 0xdb: return '[';
    case 0xdc: return '\\';
    case 0xdd: return ']';
    case 0xde: return '\'';
    case 0xe2: return '\\';
    default: break;
    }
    if (code >= 0x60 && code <= 0x69)
        return kPygameScancodeMask + (code == 0x60 ? 98 : 89 + code - 0x61);
    if (code >= 0x70 && code <= 0x87)
        return PygameFunctionKey(code - 0x70 + 1);
    if (code >= 'A' && code <= 'Z') return code + ('a' - 'A');
    if (code >= 0x21 && code <= 0x7e) return code;
    return 0; // K_UNKNOWN
}

inline int MapModifiersToPygame(int modifiers) {
    int result = 0;
    if (modifiers & (kAetherModifierShift | kGodotModifierShift))
        result |= kPygameKmodShift;
    if (modifiers & (kAetherModifierAlt | kGodotModifierAlt))
        result |= kPygameKmodAlt;
    if (modifiers & (kAetherModifierControl | kGodotModifierControl))
        result |= kPygameKmodControl;
    if (modifiers & kGodotModifierMeta) result |= kPygameKmodGui;
    // No raw SDL passthrough: Aether's echo=0x80 would become SDL's RCtrl;
    // mouse-held/cancel bits are not keyboard modifiers either.
    return result;
}

inline bool IsAetherKeyRepeat(int modifiers) {
    return (modifiers & kAetherModifierEcho) != 0;
}

}  // namespace aetherkiri::renpy::input_mapping
