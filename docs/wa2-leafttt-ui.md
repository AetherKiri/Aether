# WA2 in the Aether library UI

WA2 is provided by the private [AetherLeafTtt](https://github.com/AetherKiri/AetherLeafTtt) submodule at `packages/AetherLeafTtt`, independently from AetherInternal and the KiriKiri runtime. The normal runtime feature defaults remain enabled. A selective development build can set `AETHERKIRI_RUNTIMES_DEFAULT=OFF` and `AETHERKIRI_ENABLE_WA2=ON`, reuse a compatible vcpkg installation and disable manifest installation.

Import the installed game directory through Aether’s normal Import action. The native probe recognizes WA2.exe, script.pak and BGM.PAK case-insensitively; the library retains `engine=wa2` and a directory launch target. Selecting the card and Play uses the ordinary main.tscn game viewport. WA2 selects CPU RGBA output for the session without changing the backend saved for other games. Pointer mapping uses its native 1280x720 surface even when the requested presentation surface and window size differ.

The default message size is 32px, choice size 28px. The UI passes its staged CJK sans font before opening the provider; both the message box and choice renderer honor that path. Default rows use a compact pitch so four rows with a speaker fit the message area, while explicit larger font tags retain adaptive spacing.

Run the official UI locally from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-AetherUI.ps1 -GameRoot "D:\ollama\WA2\game\WHITE ALBUM2"
```

Use `-PatchDir <overlay-root>` for a generated UTF-8 overlay, `-AutoLaunch` to open the imported game immediately, and `-Silent` for a silent UI session. Without AutoLaunch, the script imports or reuses the directory and opens its detail view so the real Play button remains available. Godot 4.7 console, a compiled Windows x64 Release extension and the current Microsoft Visual C++ x64 runtime are required. The script accepts an alternate `-GodotExe` path. It starts the actual Aether UI, not the standalone runtime probe.

Fast validation uses `scripts/wa2_ui_smoke.gd`: it instantiates main.tscn, calls the same import handler, activates the actual card and detail Play signals, and sends mouse events through Window.push_input and Main._input. It backs up/restores the library. The imported real game was identified as WA2, started in the normal viewport, and accepted title and body clicks with exact native coordinate mapping. The optional bounded font capture records a readable Chinese paragraph. This check is a short UI smoke, not a full route replay.

CI initializes the private engine using the dedicated read-only `AETHER_LEAFTTT_DEPLOY_KEY` secret, separate from Internal and SoftPal keys. No game data, translation output, or credentials are committed.
