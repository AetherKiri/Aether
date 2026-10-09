#pragma once

#include "engine_api.h"
#include "renpy_input_mapping.h"

namespace aetherkiri::renpy::input_mapping {

inline bool HasCommittedGodotText(int modifiers, uint32_t codepoint) {
    if (codepoint < 0x20 || (codepoint >= 0x7f && codepoint < 0xa0) ||
        codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff))
        return false;
    if (modifiers & kGodotModifierMeta) return false;
    const bool control = (modifiers & (kAetherModifierControl | kGodotModifierControl)) != 0;
    const bool alt = (modifiers & (kAetherModifierAlt | kGodotModifierAlt)) != 0;
    // Ctrl shortcuts are key events. Ctrl+Alt may be AltGr and can legitimately
    // supply a committed character; do not synthesize one from the keycode.
    return !control || alt;
}

template <typename Send>
engine_result_t SendGodotKeyEvents(Send&& send, bool pressed, int keycode,
                                  int modifiers, uint32_t codepoint) {
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    engine_result_t result = ENGINE_RESULT_OK;
    if (keycode != 0) {
        event.type = pressed ? ENGINE_INPUT_EVENT_KEY_DOWN : ENGINE_INPUT_EVENT_KEY_UP;
        event.key_code = keycode;
        event.modifiers = modifiers;
        event.reserved_u32 = static_cast<uint32_t>(KeyCodeSpace::Godot);
        // Ren'Py text is committed through TEXT_INPUT. Desktop and mobile
        // KEYDOWN must not carry another copy of that Unicode character.
        result = send(event);
    }
    if (result == ENGINE_RESULT_OK && pressed && HasCommittedGodotText(modifiers, codepoint)) {
        event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
        event.key_code = event.modifiers = 0;
        event.reserved_u32 = 0;
        event.unicode_codepoint = codepoint;
        result = send(event);
    }
    return result;
}

}  // namespace aetherkiri::renpy::input_mapping
