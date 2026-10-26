# SystemC runtime

The optional AetherInternal package provides the CandySoft / Interheart SystemC
ACT/SPT runtime. This is separate from YU-RIS, CatSystem2 and AliceSoft System 3.
Import the game directory through the normal visual-novel library. Format
recognition belongs to the private provider; an `.fpk` extension alone does not
select this engine.

## Player behavior

- Native backgrounds and character layers, including E-mote through the existing
  private SDK bridge.
- Dialogue, choices, automatic playback, fast-forward, voice replay and backlog.
- 96 save slots, quicksave/quickload, overwrite confirmation, return to title and
  persistent read/CG/replay progress.
- Music and CG galleries, scene replay and annotated postgame entry points.
- Host audio/video playback, movie skip and natural-completion callbacks.
- Per-game AUTO, CP932, GBK or UTF-8 text selection in the game detail page.

Saves and settings use an isolated application directory derived from the game
root. Game packages are read in place. Saves are Aether runtime saves; original
Windows saves are not imported. Scene replay preserves story flags and position
while adding newly viewed CGs to global progress.

The runtime uses a portable UI with the game's title art and content. It does not
recreate the executable's custom menu skin. Some legacy transition/effect shapes
use portable approximations. Unsupported commands produce a script/PC diagnostic.

## Validation scope

Development validation used 天気雨 (Tenkiame), including a translated data set,
on macOS arm64 Debug. The provider has no game-title or executable-hash dispatch.
Other SystemC releases still require corpus and real-flow validation; shared
engine branding does not establish compatible script layouts or opcodes.

The private package includes independent format/VM/provider unit fixtures,
read-only corpus tools, E-mote restoration checks and JSON regression cases.
JSON cases cover normal library entry, story/save/load/reopen, dynamic E-mote,
choice branching, CG/music galleries, movie completion/skip/replay and postgame
entries. Each run uses disposable application storage. They do not replace a
human full-game verification, and the verified-games lists are unchanged.

Run a case from the public repository root:

```sh
python3 tools/run_runtime_regression.py \
  packages/AetherInternal/src/systemc_runtime/tests/probes/story.json \
  --platform macos --game "$GAME_ROOT" --project apps/godot_app \
  --godot "$GODOT_BIN" --user-data-dir "$GODOT_USER_DATA" \
  --output out/systemc/regressions --timeout 180
```

`title.json` is generic. `story.json` expects two early dialogue messages;
`tenkiame-*.json` select documented sections of the development corpus. The
natural-movie case needs `--timeout 270`. The engine implementation, format
profiles, opcode coverage, build options and extension workflow are documented
in the private package's `src/systemc_runtime/README.md`.

## Build integration

`AETHERKIRI_ENABLE_SYSTEMC` defaults to ON when Internal is available. Native
unit tests use `AETHERKIRI_BUILD_SYSTEMC_TESTS`; the complete Godot application
links the SDK factory already owned by the native KiriKiri host. No second SDK
copy is introduced into the ABI library. Builds without the private SDK can run
static-content profiles; animated E-mote content reports the missing capability.

Only macOS arm64 was built and exercised for this change. Other platforms and
older macOS releases have not been validated. The installed private macOS SDK
archive currently reports a deployment target newer than the application's
minimum, so the successful local build does not establish that minimum OS floor.
