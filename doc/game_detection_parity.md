# Native game detection parity

Game import and launch in the Godot shell use the detector selected under
**Settings → Compatibility → Game Detection**. **Automatic** uses Native on
prerelease builds and Legacy Godot on stable builds. Only explicit **Native**
and **Legacy Godot** selections are saved. Choosing **Automatic** clears the
override, and older draft settings that stored only the resolved mode are
treated as Automatic. The choice takes effect on the next detection and is
independent of the Render Pipeline selection. Launch continues through the existing player selection and
`GameLaunchEntry` code. In particular, a detected file is an import hint and
the library can still store a different user-selected entry.

The standalone C++ entry point is
[`aether::game_detection::DetectGame(path)`](../bridge/game_detection/include/aether/game_detection.h)
in `aether_game_detection`. It returns the runtime ID, the game root, marker
signals, the detected launch file, the Ren'Py game directory when applicable,
and the winning Provider's score when a Provider probe changed the fallback.
The Godot adapter supplies Godot's filesystem access and case conversion for
virtual paths and platform imports. Display title extraction still uses the
existing Godot title reader. Flutter can reuse the C++ detector through its
native adapter. The engine C ABI, Provider v1, and engine-level `auto` dispatch
follow their existing contracts.

## Format and entry coverage

The direct rules use [`GameMetadata.inspect`](../apps/godot_app/scripts/game_metadata.gd)
in the order below. The dedicated Flash library has its own matching context.

| Order | Existing runtime ID | Legacy rule and entry hint | macOS arm64 parity evidence |
| --- | --- | --- | --- |
| 1 | `tyranoscript` | `tyrano_entry_file` checks plain HTML, unpacked Electron layouts, then Electron ASAR paths. HTML and ASAR both require the four project markers. The matched relative entry is the launch hint. | Plain, both unpacked layouts, both ASAR paths, malformed ASAR, ASAR with a link, mixed Ren'Py, and path case matched. |
| 2 | `renpy` | `renpy_game_directory` checks `game`, macOS bundle layout, then the root. Loose `.rpy` files, RPC2 `.rpyc`, and RPA 2.0/3.0 archives qualify. Subdirectory depth, excluded names and symlink behavior are preserved. | Loose, compiled, packed, game-root depth, excluded/deep paths, symlinks and mixed ONS matched. The dedicated directory hint matched. |
| 3 | `n2system` | `is_n2system_directory` recognizes the explicit Aether profile, qualified `profiles.json`, NPA signatures, or the PAK/INI combination. This ID also has a Provider fallback. | Explicit and selected profiles, legacy JSON trailing comma, NPA, PAK, invalid profiles and partial PAK matched. |
| 4 | `xsystem4` | `system40.ini` or `alicestart.ini` with an AIN file. | Both INIs, a partial match, and competing System 3.5/ONS markers matched. |
| 5 | `xsystem35` | A filename ending in `sa.ald` or `adisk.ald`. | Both branches and competing System 3 markers matched. |
| 6 | `system3` | A scenario DAT/PAT marker paired with `acg.dat` or `gcg.dat`. | All four scenario names, both graphics names, a missing partner, and competing ONS markers matched. |
| 7 | `cmvs` | `is_cmvs_directory` checks CPZ in `data/pack/script.cpz` and PS2A in either startup script. | Both startup extensions, invalid magic and competing ONS markers matched. |
| 8 | `exhibit` | `exhibit.ini` with a root or nested RLD file. This ID also has a Provider fallback. | Both RLD layouts, a missing RLD and competing ONS markers matched. |
| 9 | `rfvp` | `hcb_launch_file` validates the HCB header and syscall table. An explicitly supplied valid HCB is used, then the first visible file, then a hidden file. | Visible preference, hidden-only fallback, explicit hidden selection, invalid headers and competing ONS markers matched. |
| 10 | `onscripter` | The five exact script markers and the `onscript.nt` prefix. | Every marker, mixed case and competing XP3/Siglus markers matched. |
| 11 | `catsystem2` | `_is_catsystem2_package` checks the launcher and INT/boot combinations, including packed projects with `boot.dfn` and `kcs.int`. This ID also has a Provider fallback. | Launcher with INT or boot, packed markers, and a launcher alone matched. |
| 12 | `yuris` | The SDK launcher, loose `system_start` scripts, YSCF/YSCM compiled headers, or a YPF signature in the root or `pac`. The SDK launcher hint keeps the legacy spelling. This ID also has a Provider fallback. | Loose, compiled, truncated, hidden, and mixed-case packs matched. The launch hint matched. |
| 13 | `artemis` | `_is_artemis_package` checks the INI name or the PFS/BOOT combination. PFS without XP3 is the archive-only fallback. | Loose INI, IET boot, PFS-only and PFS mixed with XP3 matched. |
| 14 | `siglus` | `gameexe.ini`, `gameexe.dat`, or `scene.pck`. | Each marker matched. |
| 15 | `mages` | Script and system MPKs plus a background, character or model MPK. This ID also has a Provider fallback. | Valid and partial MPK sets matched. |
| Fallback | `kirikiri` | Prefer loose startup scripts without a file hint. Otherwise prefer `data.xp3`, another XP3, then an EXE in directory enumeration order. Unknown and missing paths keep the KiriKiri ID. | Loose scripts, XP3 priority and enumeration, launcher-only, unknown directory, and missing paths matched. |
| Flash library | `flash` | `VideoLibrary.entry_info` accepts an existing case-insensitive `.swf` file in the Flash catalog. The Flash player receives that file. | Mixed-case SWF, SWC rejection and the same SWF in the visual-novel catalog matched. |

TyranoScript and Ren'Py player entry discovery is also exercised separately from
the visual-novel matching order. The Godot parity suite compares runtime ID,
stored marker signals, entry hints, and existing title metadata.

## Provider fallback coverage

The order and thresholds come from
[`_probe_game_runtime_kind`](../apps/godot_app/scripts/main.gd).
The native detector uses `engine_probe_runtime_provider` only when the direct
format check returns KiriKiri. The first eligible Provider wins. An unavailable
Provider has a negative score and the fallback continues. A direct marker can
still identify a format when its optional Provider is unavailable.

| Order | Existing runtime ID | Minimum score | Parity result |
| --- | --- | --- | --- |
| 1 | `exhibit` | 1 | Matched |
| 2 | `systemc` | 1 | Matched |
| 3 | `escude` | 90 | Matched |
| 4 | `entisgls` | 90 | Matched |
| 5 | `advhd` | 90 | Matched |
| 6 | `bgi` | 90 | Matched |
| 7 | `yuris` | 1 | Matched |
| 8 | `catsystem2` | 1 | Matched |
| 9 | `softpal` | 1 | Matched |
| 10 | `minori` | 1 | Matched |
| 11 | `wa2` | 1 | Matched |
| 12 | `mages` | 1 | Matched |
| 13 | `n2system` | 1 | Matched |

The same [score matrix](../apps/godot_app/tests/game_detection_probes.json) runs
against the Godot fallback and the C++ rule. It covers absent Providers, zero
scores, the 89/90 boundary, competing scores, and a direct marker taking
precedence. A standalone test also registers test Providers through the real C
ABI and calls the filesystem entry point. Proprietary games and Provider
implementations are unnecessary for verifying score handling.

## Verification

- Local macOS arm64 with Godot 4.7.2. The Godot/native parity test passed all
  79 filesystem cases and 19 Provider score cases. The existing metadata,
  launch-entry, RFVP import, Flash, TyranoScript, and Ren'Py library tests also passed.
- Local standalone Debug build with the Godot extension disabled. All 33 CTest
  cases passed, including the two native detection tests and the existing
  engine dispatch tests.
- Two fresh Godot processes loaded the Alpha default and then the saved legacy
  setting from the same isolated settings directory. Each mode imported and
  started an ONS game through the existing player and produced a frame. The
  file-picker callback retained a manually chosen XP3 in both modes. The
  existing KiriKiri player opened that archive and produced a frame. Changing
  the detector left the Render Pipeline selection intact.
- The Godot parity suite also simulates upgrades between prerelease and stable
  builds. It verifies that unrelated settings saves omit the default, a draft's
  saved default does not override stable behavior, explicit choices survive
  upgrades, and returning to Automatic clears the saved choice.
- The repository's macOS and Linux CI jobs run the Godot parity and settings
  suite. The local results above describe the tested macOS build and fixtures.
- The existing mocked `runtime_player_reopen_test.gd` reported the same 18
  failures on base commit `03eab283` and on this change. The import and launch
  test above uses the real ONS and KiriKiri players.

**Observed differences**. There were no old/new mismatches in the test matrix.
The parity test prints the case, input path, field, legacy result, and native
result if a future case differs.

### Reproduction

Run from a checkout with the Godot extension built.

```sh
"$GODOT_BIN" --headless --path apps/godot_app \
  --script res://tests/game_detection_parity_test.gd
ctest --test-dir out/native-game-detection-standalone \
  -R 'Native detection matches|Standalone detection can' --output-on-failure --no-tests=error
```

For import, startup and persistence, use a Godot Debug build with ONS and
KiriKiri enabled and two local copies of an ONS game. The integration test uses
a separate Godot user directory and the repository's KAG3 demo.

```sh
test_id="$(uuidgen)"
"$GODOT_BIN" --headless --path apps/godot_app \
  --script res://tests/game_detection_launch_test.gd -- "$test_id" native legacy "$ons_copy_a"
"$GODOT_BIN" --headless --path apps/godot_app \
  --script res://tests/game_detection_launch_test.gd -- "$test_id" legacy native "$ons_copy_b"
```
