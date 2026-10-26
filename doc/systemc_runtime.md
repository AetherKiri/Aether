# SystemC runtime

The optional AetherInternal package provides the CandySoft / Interheart SystemC
ACT/SPT runtime. This is separate from YU-RIS, CatSystem2 and AliceSoft System 3.
Import the game directory through the normal visual-novel library. Format
recognition belongs to the private provider; an `.fpk` extension alone does not
select this engine.

## Player behavior

- Game-provided logo sequence and title, followed by the original menu artwork,
  hit regions and normal/hover/pressed button states.
- Native backgrounds and character layers, including E-mote through the existing
  private SDK bridge; original transition masks and effect textures.
- Dialogue, choices, auto, read-only/all-text skip, voice replay and backlog.
- 100 normal slots, 10 automatic slots and 10 quick slots, with the original
  save/load confirmation flow and persistent read/CG/replay progress.
- The game's CG gallery and scene-replay categories, unlock rules and entry scripts.
- Original settings controls for text/auto speed, window opacity, effects,
  E-mote animation, audio volume/mute and display mode.
- Host audio/video playback, movie skip, natural completion and pause callbacks.
- Per-game AUTO, CP932, GBK or UTF-8 text selection in the game detail page.

UI descriptors are read as data from the game's executable; no Windows code is
executed. Missing or ambiguous profiles fail with a diagnostic. The runtime does
not substitute a generic title screen or add menus absent from the game.

Saves and settings use an isolated application directory derived from the game
root. Game packages are read in place. Saves are Aether runtime saves; original
Windows saves are not imported. Scene replay preserves story flags and position
while adding newly viewed CGs to global progress. Active transition captures are
saved with their clocks so loading does not reconstruct a different outgoing frame.

## Validation scope

Development validation used 天気雨 (Tenkiame), including a translated data set,
on macOS arm64 Debug. The provider has no game-title or executable-hash dispatch.
Other SystemC releases still require corpus and real-flow validation; shared
engine branding does not establish compatible script layouts or opcodes.

The private package includes independent format/VM/provider, native-UI and
rendering fixtures, read-only corpus tools, E-mote restoration checks and JSON
regression cases.
JSON cases cover the logo/title sequence through normal library entry, settings
persistence, story/save/load/reopen, dynamic E-mote, choice branching, CG gallery,
movie completion/skip/replay and the native extra-story entries. Each run uses
disposable application storage. All eight cases passed in the exported Debug
application, alongside 90 SystemC and 140 shared-text/provider test cases. These
checks do not replace human full-game verification; the verified-games lists
are unchanged.

Run a case from the public repository root:

```sh
python3 tools/run_runtime_regression.py \
  packages/AetherInternal/src/systemc_runtime/tests/probes/story.json \
  --platform macos --game "$GAME_ROOT" --project apps/godot_app \
  --godot "$GODOT_BIN" --user-data-dir "$GODOT_USER_DATA" \
  --output out/systemc/regressions --timeout 180
```

`title.json` covers the supported native UI profile. `story.json` expects two
early dialogue messages; `tenkiame-*.json` select documented sections of the
development corpus. The
natural-movie case needs `--timeout 270`. Movie frame assertions use
`"frame_source": "movie"` to inspect the decoded video pixels and presentation,
since host video can advance independently of the script-rendered surface. The
engine implementation, format profiles, opcode coverage, build options and
extension workflow are documented in the private package's
`src/systemc_runtime/README.md`.

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
