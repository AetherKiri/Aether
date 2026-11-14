# Game save export and iCloud Drive

Astryx game details contains a **Saves** section. **Export saves** packages the
selected game's save files and thumbnails as a ZIP, then opens the native share
chooser on Android, iOS and macOS. Other desktop platforms use a save-file dialog.
The browser preview only demonstrates the controls; native actions run in Godot.

On iOS and macOS, **Upload to iCloud** and **Sync from iCloud** use an iCloud Drive
folder chosen through the system directory picker. Choose the same folder on both
devices the first time. A security-scoped bookmark remembers that choice. This
uses the user's existing Drive rather than requiring a new app-owned CloudKit
container or new signing entitlements.

Each trimmed game display name gets its own readable folder plus a name hash,
containing `saves.zip`. Names must match on both devices; renaming a game creates
a different cloud location. The archive also records the engine, which must match
before restoring. Uploading replaces that game's cloud ZIP. Upload completion
means the file was saved to Drive locally; the OS finishes network transfer.
These are explicit actions, not background synchronization during gameplay.

Downloading requires confirmation, validates the complete archive, and backs up
existing local saves to `user://save_backups/<game-folder>/<timestamp>.zip` before
writing. It replaces matching files and retains local files absent from the ZIP.
If a write fails, completed writes are rolled back. Other games are never
enumerated or restored. Transfers capture the current game before asynchronous
work, so changing the selected game cannot redirect a pending restore. Launch
and removal are blocked while a transfer is active.

## Archive and storage contract

`game_save_locations.gd` maps runtime-owned locations to logical save banks. The
ZIP contains `main/<relative-save-file>` and `aether-save.json` with the game name,
engine, format version, file lengths and SHA-256 hashes. It contains no absolute
host paths. Save locations come from the current host, never from archive input.

The resolver supports the game-local `savedata` convention and the established
Ren'Py, TyranoScript, YU-RIS, SystemC, Siglus, ONScripter, CatSystem2, BGI,
System4/3.5/3, RFVP, MAGES and WA2 locations. RFVP follows the configured encoding;
MAGES selects only the detected title's profile. Cache/font-cache folders and
known non-save metadata are
excluded; root-level engines use explicit file allowlists.

Legacy Minori saves share an application-wide directory without a reliable game
owner, and SoftPal save-bank identities are not yet exposed to the shell.
Those cases return an explicit unsupported-location message instead of copying
shared application data. Engine-specific custom save-path overrides outside the
mapped banks require an additional resolver; they must not fall back to scanning
the whole game or user-data directory.

Archives are bounded to 10,000 files, 128 MiB per file and 1 GiB total. Import
checks the ZIP directory before decompression and rejects traversal, symlinks,
case-duplicate paths, unknown banks, encryption, corrupt hashes and mismatched
game identities. Android shares a temporary copy through a dedicated, unexported
FileProvider restricted to its save-sharing cache directory, with temporary read
permission. Share copies remain available for receiving apps and are pruned on
later exports after 24 hours. Cloud staging files are removed when finished.

## Focused checks

Run with the repository's Godot binary and `--headless --path apps/godot_app`:

- `--script res://tests/game_save_archive_test.gd`: round trips, identity checks,
  traversal/link rejection, backup and partial-write rollback, engine banks.
- `--script res://tests/game_save_transfer_test.gd`: delayed callbacks after
  navigation, concurrent-operation rejection, cancellation and backup retention.
- `--script res://tests/astryx_shell_test.gd`: save controls, sync confirmation,
  iOS deletion wording and equal confirmation-button sizes, default UI choice.

Native share UI and iCloud account/network behavior additionally require device
checks. Local tests do not prove cross-device iCloud delivery.
