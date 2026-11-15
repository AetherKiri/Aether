# Astryx application identity

The classic blue two-whale icon remains in `assets/icon.png` and `assets/icons/`.
Astryx uses the graphite variant here, independently of its light/dark theme.
`scripts/ui/app_icon.gd` selects the in-app and runtime system identity from the
saved interface version. New installations export Astryx as their primary icon.

`master.png` was generated with the built-in imagegen tool from the existing icon.
Final prompt:

> Make a production-ready neutral-gray color variant of the provided Aether icon.
> ONLY recolor: original exact two whale silhouettes and facial expressions,
> placement and proportions must remain identical, small Godot emblem and folded
> corner retained. Whale bodies graphite #262626 to #474747, bellies #919191, eye
> and mouth cutouts white, corner light gray #d4d4d4, Godot emblem graphite. Neutral
> white/off-white tile. NO blue or other hue. Keep the original composition at
> exactly the same size, square 1024x1024. For this system app-icon master, output
> a fully opaque square white canvas to the edges, no transparency, no artificial
> outer border or external shadows. Clean smooth edges, no jagged cutout artifacts,
> no textures added, no text, no redesign. Preserve subtle existing embossing on
> the whales. The only difference from the source should be the neutral
> charcoal/gray palette and the fully opaque white outer corners required by iOS
> icon packaging.

Run `godot --headless --script tools/generate_app_icons.gd` from the repository
root to regenerate the platform sizes. Packaging retains the classic tile's
alpha mask for desktop/in-app use and emits opaque Apple mobile icons and
Android adaptive layers. No generation service is needed at build time.

- iOS: the primary icon is Astryx, with `Classic` registered for **both** iPhone
  and iPad. `tools/stage_app_icons.py` adds the images to the exported Xcode
  project's resources. UIKit's public
  [alternate icon API](https://developer.apple.com/documentation/uikit/uiapplication/setalternateiconname(_:completionhandler:))
  owns the system notification shown when the icon changes.
- Android: retain `GodotAppLauncher` as the primary alias for upgrade continuity,
  add `AetherClassicLauncher`, and switch aliases with `DONT_KILL_APP`. Android 13+
  changes both atomically. Older versions enable the destination before disabling
  the previous alias. Recents receives the corresponding task icon. Launcher
  refresh timing is OS-owned; Android's application-info icon stays primary.
- macOS: update the running Dock / app-switcher icon. Finder keeps the default
  Astryx bundle icon: custom-icon metadata adds a resource fork / FinderInfo,
  which fails strict code-signing validation. The signed bundle stays immutable.
- Other desktop platforms: Godot updates the window/taskbar icon. Existing
  Windows shortcuts and Linux desktop files are not rewritten.

Editor/headless previews never change the editor application's system icon.
