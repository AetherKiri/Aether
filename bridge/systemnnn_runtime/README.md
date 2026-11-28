# SystemNNN

Aether recognizes an extracted game by its `spt/sys.spt` entry and registers the `systemnnn` Provider v1 runtime. Select the directory for the edition you want to play. The game library and standalone Native Host use the same runtime ID. The prerelease Automatic Host and the explicit Native Host preview create the session through `RuntimeSession`. The Godot Host setting opens the same Provider and save bank through the existing engine API.

The [Emberfall submodule](../../packages/AetherSystemNNN) supplies the script interpreter, resource loaders, compositor, audio mixer, PC save codec and Android player. The Android build launches the upstream Activity in its own process and returns to the library when it closes. Other native hosts publish the game's RGBA frames and use its SDL presenter for menus and dialogue. Script movies use the media service supplied by the host. The standalone probe exercises the session without a Godot or Flutter SDK.

Numbered PC slots live in the game's `sav` directory. Trial editions use the upstream `tdata` prefix. The SDL presenter also keeps its system progress and settings in this directory. Right-click or Escape opens the system menu, Enter or a click advances dialogue, arrow keys select buttons, and F5/F9 write and restore the configured quick slot.

Build the standalone probe by enabling `BUILD_NATIVE_HOST` and `AETHERKIRI_ENABLE_SYSTEMNNN`. Running it without arguments checks detection and host selection. The optional playback test writes to a disposable copy of a game. It opens the title, reads a nonuniform frame, pauses and resumes, advances to two distinct lines of dialogue, writes a PC slot and checks the restored script position in a fresh session.

```sh
cmake --build out/native-host --target systemnnn-native-probe
out/native-host/bridge/native_host/systemnnn-native-probe "/path/to/disposable-game-copy" apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf "/path/to/probe-output"
```
