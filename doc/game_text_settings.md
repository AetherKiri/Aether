# Per-game text encoding and fonts

Astryx **Game information** exposes independent **Text encoding** and **Game
font** editors. Edit disappears while a row is open; Save and Cancel appear
below its inputs. Encoding changes, file selection and resetting to defaults
remain drafts until Save. Rotation preserves the draft. Leaving the game,
closing its information section or Cancel discards it, including late picker
results. Changes apply on the next game launch in either shell interface.

| Engine | Explicit text encodings | Font override |
| --- | --- | --- |
| ONScripter Yuri, RFVP | CP932 / Shift-JIS, GBK, UTF-8 | TTF / OTF |
| YU-RIS, SystemC, BGI, ADVHD, Escu:de, SoftPal, CatSystem2 | CP932 / Shift-JIS, GBK, GB18030, BIG5, UTF-8 | TTF / OTF |
| EntisGLS | Native Unicode; no byte-decoding selector | TTF / OTF |

Native Unicode representations remain intact: ADVHD's modern UTF-8 scripts
and SoftPal's native translation dictionaries are not reinterpreted as legacy
bytes. Encoding selection controls the applicable byte-text path; it does not
translate text or add glyphs missing from a chosen font.

Settings live in `aether_config.json` in the game's library directory:

```json
{
  "text": {
    "encoding": "GBK",
    "font_file": "aether_fonts/<content-sha256>/MyFont.otf"
  }
}
```

Both fields use `""` to inherit the engine's existing behavior. Missing fields
also inherit; existing YU-RIS, SystemC and RFVP library encoding selections
remain a fallback until an explicit JSON encoding is saved. An explicit empty
JSON encoding supersedes that old library selection. No global UI font or
language is changed. Each launch rereads the file, and one game's settings do
not become the next game's defaults.

Font selection validates a nonempty TTF/OTF up to 32 MiB and previews the loaded
font. Save copies it into `aether_fonts/<SHA-256>/<original-filename>` beneath
the game, preserving its bytes and filename. Repeated imports of the same font
reuse that path. iOS/macOS selection first copies the file while native access
is valid, then loads the draft into memory and removes the temporary copy.
Cancel does not copy anything into the game. Reset saves an empty `font_file`;
it does not delete user files or previous imports. Fonts are resolved relative
to the game, so moving the entire directory retains the selection.

The shared `GameTextSettings` loader feeds ONS/RFVP startup directly and feeds
the existing `GameHooks` font/encoding consumers for the other eight engines.
Nonempty JSON choices override Lua patch defaults without changing registered
resources or creating `aether.lua`. Empty values retain patch/native defaults.
YU-RIS separates its imported game root from its detected system directory;
RFVP retains the library root when the selected HCB entry is nested below it.
The shell sends base font options before startup only, so applying live app
settings cannot replace a native game font.

JSON uses canonical encoding names from the table (`CP932`, not its UI alias).
Invalid text settings or missing/invalid font paths stop native startup with
an `aether_config.json` diagnostic. Configurations are limited to 1 MiB. The
editor preserves unrelated fields, including `rendering`, and replaces JSON
through a sibling temporary file. Failed saves retain the editor and draft;
a newly copied font is removed if the JSON write fails. Malformed existing
JSON is not overwritten. A missing font can be cleared with Reset and Save.

Validation:

```sh
cmake --build out/macos/debug --target aether_game_text_settings_tests
out/macos/debug/bridge/game_hooks/aether_game_text_settings_tests
godot --headless --path apps/godot_app --script res://tests/game_text_config_test.gd
godot --headless --path apps/godot_app --script res://tests/game_render_config_test.gd
godot --path apps/godot_app --script res://tests/astryx_shell_test.gd
```

These cover the ten-engine settings contract, Lua priority, session isolation,
font import/reset, invalid input, legacy migration, launch options and actual
phone/tablet editor geometry. They do not substitute for playing a title from
each engine on physical iOS devices. The React preview uses the original Astryx
components and browser FontFace previews; its per-game changes are in memory.
