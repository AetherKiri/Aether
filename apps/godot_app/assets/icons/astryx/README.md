# Aether app icons

The Classic and Astryx light interfaces share the Aether rounded tile. Astryx
dark uses the light mark on a dark tile. The masters and copyright notice are
maintained in [Aether-Branding](https://github.com/AetherKiri/Aether-Branding).
The assets in this repository were generated from
[branding revision 0250ed3](https://github.com/AetherKiri/Aether-Branding/tree/0250ed3a9bbe59067a8ce1ac4165b65a3516cc91).

To regenerate these assets, run `python3 tools/generate_app_icons.py ../Aether-Branding`
from the repository root with Pillow 9.1 or later installed. The build uses the
checked-in exports and the Icon Composer package under `tools/branding/`.

- iOS and iPadOS use the layered branding package with Xcode 26 or later. Xcode
  generates the older-system icons from the same layers. The saved `Classic`
  and `AstryxDark` alternate icon names are supported on iPhone and iPad. Older
  Xcode versions use the opaque PNGs from the Godot export and the staged
  alternate PNGs.
- Android uses separate foreground and background layers for adaptive launchers
  and rounded PNGs for legacy launchers and Recents. The existing launcher
  aliases preserve installed app shortcuts across upgrades.
- macOS exports the rounded icon for Finder and uses the active interface
  variant in the Dock. Godot uses the same default on Windows and Linux and
  exports it as the Web favicon.
- The app previews the corresponding icon while editing the Astryx theme and
  updates the runtime icon after a successful save. Editor and headless runs
  leave the host application's icon alone.

Copyright © 2026 AetherKiri. All rights reserved. See the
[Aether-Branding copyright notice](https://github.com/AetherKiri/Aether-Branding/blob/main/COPYRIGHT.md).
