# Game save export and iCloud Drive

Astryx game details contains a **Saves** section. **Export saves** packages the
selected game's save files and thumbnails as a ZIP, then opens the native share
chooser on Android, iOS and macOS. Other desktop platforms use a save-file dialog.
The browser preview only demonstrates the controls; native actions run in Godot.

On iOS, **Automatic iCloud sync** is a per-game switch, off by default. It is
stored as `saves.icloud_auto_sync` in that game's `aether_config.json`. Enabling
it, or starting an enabled game, first opens the app's iCloud Documents container:
`aether/Games/<game-folder-name>/savedata`. If that bank exists, a complete download
replaces the local `Games/<game-folder-name>/savedata`; otherwise the local bank
is uploaded. The folder name identifies the game, independently of its editable
library display title. Standalone archives need their own game folder.

While a game is running, a utility worker checks local savedata every second.
Only changed files are copied; local deletions propagate to this game's cloud
bank. Closing or backgrounding the game requests a final check. The OS performs
the subsequent network upload. Missing accounts, unresolved conflicts and I/O
errors are reported, not treated as an empty cloud bank. Downloads finish in a
visible work folder before replacing local data, with recovery across the final
rename. No other game's bank is enumerated or modified. Sync covers the game's
`savedata` directory; engine-specific storage outside that directory remains
available through ZIP export, not this automatic watcher.

On macOS, **Upload to iCloud** and **Sync from iCloud** retain the manual system
folder picker and security-scoped bookmark. Each trimmed display name gets a
readable folder plus a name hash containing `saves.zip`. Names and engines must
match before restoring. This manual ZIP format is separate from iOS automatic
savedata sync. Restoring a ZIP confirms the action, validates the archive and
backs up existing saves to `user://save_backups/<game-folder>/<timestamp>.zip`.
It replaces matching files and retains files absent from the ZIP; failed writes
are rolled back. Transfers capture the selected game before asynchronous work.

## iOS signing setup

The app target requires iCloud Documents and container `iCloud.<bundle-id>`.
The default production container is `iCloud.com.liuyu.aether.aether`.

1. In Apple Developer, register that identifier under **Identifiers → + →
   iCloud Containers**.
2. Edit the host App ID, enable **iCloud**, and associate the container using
   **Edit**. Save the App ID. In Xcode the service is **iCloud Documents**.
3. Regenerate the host App Store distribution provisioning profile. Preserve its
   existing App Group capability. The import extension profile is unchanged.
4. Replace GitHub secret `IOS_PROVISIONING_PROFILE_BASE64` with the new profile's
   Base64. The packaging script validates both container identifier entitlements
   and the `CloudDocuments` service before altering signing settings.

See Apple's [iCloud configuration](https://developer.apple.com/documentation/xcode/configuring-icloud-services)
and [container registration](https://developer.apple.com/help/account/identifiers/create-an-icloud-container).
Actual account access, provider download and cross-device network delivery require
an entitled device build; filesystem tests do not validate them.

## Import and cache storage

Sharing queues a small in-place bookmark; the app copies game bytes directly into
`Games/Importing-<UUID>/payload`, with a bounded 1 MiB buffer. Publishing uses a
same-volume rename, not a second full copy. Cancellation removes the partial
copy; startup cleans interrupted marked work. Old app-owned hidden staging is
migrated or made visible for recovery. A provider must supply an in-place URL.

The game-detail **Cache** section measures disposable per-game storage and offers
**Clear**. New runtime caches live under `cache/games/<path-hash>`; known legacy
per-game caches are included. Clearing never removes savedata. iOS game deletion
removes the game and these caches directly, without a hidden trash directory.
Unattributed shared caches from old versions are not assigned to arbitrary games.

## Archive and storage contract

`game_save_locations.gd` maps runtime-owned locations to logical save banks. The
ZIP contains `main/<relative-save-file>` and `aether-save.json` with the game name,
engine, format version, file lengths and SHA-256 hashes. It contains no absolute
host paths. Save locations come from the current host, never from archive input.

Aether writes new System 1–3, System 3.5/3.9, System 4, MAGES, RFVP, SoftPal, Minori and TyranoScript progress beneath `savedata/` in the game folder. RFVP separates scripts and encodings; MAGES separates profiles. WA2 keeps its existing slots in the game root and stores global flags in `savedata/wa2/`. Flash stores SharedObjects next to the SWF under `savedata/flash/`. A Flash folder may hold objects shared by several SWFs, so this folder is not offered as a single-game save archive.

When the game next opens, Aether copies identifiable old saves into the new location without replacing an existing local bank or deleting the originals. Flash migrates each old object when the game requests it. The game folder must be writable for these engines; when preparation fails, Aether leaves the old files intact rather than writing a new save in the old location. Move or copy the whole game folder after migration to keep its local saves.

Older Minori saves are shared and do not name their game. If they all belong to the selected game and the local save folder is empty, open the game's **Saves** section and choose **Recover Legacy Saves**. Aether copies recognized slots and the shared system file only after you confirm. If only an old `system.dat` remains, keep it as a backup; Aether cannot identify its game or safely offer automatic recovery.

Save archives use the current game bank, not the entire game or application data directory. The resolver can read some identifiable legacy banks before the first launch; downloads write to the game folder. Launch and close SoftPal or RFVP once before syncing so the provider can migrate any legacy bank. Cache, font-cache folders, and migration markers are not part of the archive.

Archives are bounded to 10,000 files, 128 MiB per file and 1 GiB total. Import
checks the ZIP directory before decompression and rejects traversal, symlinks,
case-duplicate paths, unknown banks, encryption, corrupt hashes and mismatched
game identities. Android shares a temporary copy through a dedicated, unexported
FileProvider restricted to its save-sharing cache directory, with temporary read
permission. Share copies remain available for receiving apps and are pruned on
later exports after 24 hours. Cloud staging files are removed when finished.

## Focused checks

Run with the repository's Godot binary and `--headless --path apps/godot_app`:

- `--script res://tests/game_local_save_test.gd`: migration, portable saves, explicit Minori recovery, and protection of existing local saves.
- `--script res://tests/game_save_archive_test.gd`: round trips, identity checks,
  traversal/link rejection, backup and partial-write rollback, engine banks.
- `--script res://tests/game_cache_test.gd`: cache size, isolation, savedata
  preservation and permanent deletion.
- `--script res://tests/game_save_sync_test.gd`: defaults, config persistence,
  launch gating and runtime lifecycle.
- `--script res://tests/game_save_transfer_test.gd`: delayed callbacks after
  navigation, concurrent-operation rejection, cancellation and backup retention.
- `--script res://tests/astryx_shell_test.gd`: save controls, sync confirmation,
  iOS deletion wording and equal confirmation-button sizes, default UI choice.

Native share UI and iCloud account/network behavior additionally require device
checks. Local tests do not prove cross-device iCloud delivery.
