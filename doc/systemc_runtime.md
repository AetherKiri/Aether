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
- Profile-defined manual, automatic and quick slots, with the original save/load
  confirmations, protection/copy/move/delete controls and persistent progress.
- The game's CG gallery and scene-replay categories, unlock rules and entry scripts.
- Original settings controls for text/auto speed, window opacity, effects,
  E-mote animation, audio volume/mute and display mode.
- Host audio/video playback, movie skip, natural completion and pause callbacks.
- Per-game AUTO, CP932, GBK or UTF-8 text selection in the game detail page.

UI descriptors are read as data from the game's executable; no Windows code is
executed. Missing or ambiguous profiles fail with a diagnostic. The runtime does
not substitute a generic title screen or add menus absent from the game.

All writable game state, including saves, settings and global progress, lives in
`<game>/savedata/`. Host caches remain separate. Matching Aether saves from the old
application directory migrate once without replacing existing saves or deleting
the originals. Game packages are read in place. Per-slot saves use Aether's format;
supported configurable profiles can import original `system.dat` global CG/replay
progress without rewriting the original file. Scene replay preserves story flags
and position while adding newly viewed CGs to global progress. Active transition
captures are saved with their clocks so loading retains the outgoing frame.

## Validation scope

Development validation used 天気雨 (Tenkiame), including a translated data set,
WANNABE→CREATORS, and 神様のしっぽ ～干支神さまたちの恩返し～ on macOS arm64
Debug. These exercise classic, configurable and expanded configurable native UI
profiles. The provider has no game-title or executable-hash dispatch. Other
SystemC releases still require corpus and real-flow validation; shared engine
branding does not establish compatible script layouts or opcodes.

The private package includes independent format/VM/provider, native-UI and
rendering fixtures, read-only corpus tools, E-mote restoration checks and JSON
regression cases. The final development pass included 130 SystemC test cases,
seven Python runner tests and 20 cases in the exported Debug application, with
289 presented-frame assertions and no host rendering errors. JSON cases cover
original startup/settings, saves and reopen, dynamic E-mote, choices, CG/replay,
movies, music, character controls, backlog and novel-page restoration. Each run
uses both a disposable game copy and isolated application storage, since saves
are written inside the game directory.

WANNABE's original full-progress file was imported and remained unchanged.
No original `system.dat` was found in the supplied Kamishippo directory, so its
gallery/replay checks used progress earned by route traversal; its original
full-save import remains unverified. Independent fixtures cover both supported
global-progress layouts. These checks do not replace human full-game verification;
the verified-games lists are unchanged.

Run a case from the public repository root:

```sh
python3 tools/run_runtime_regression.py \
  packages/AetherInternal/src/systemc_runtime/tests/probes/story.json \
  --platform macos --game "$DISPOSABLE_GAME_COPY" \
  --app out/godot/macos/debug/Aether.app --user-data-dir "$GODOT_USER_DATA" \
  --output out/systemc/regressions --timeout 180
```

`title.json` covers the classic native UI profile. `story.json` expects two
early dialogue messages; `tenkiame-*.json`, `wannabe-*.json` and
`kamishippo-*.json` cover their respective development corpora. The
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
