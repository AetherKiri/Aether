# Astryx application identity

The classic blue two-whale icon remains in `assets/icon.png` and `assets/icons/`.
Astryx Light uses `master.png` (white tile, pure black whale bodies), and Dark uses
`dark/master.png` (black tile, white whale bodies). Both retain gray bellies and a
light gray folded corner with pure black robot linework.

`scripts/ui/app_icon.gd` selects the interface and theme identity. Draft theme
changes preview the corresponding icon in the app; system icons change only
after the user saves successfully. Canceling, failed persistence, or saving an
unchanged theme does not change the system icon. Classic retains its blue icon.
New installations export Astryx Light as their primary icon.

The masters were edited from the approved existing icon using the built-in
imagegen tool. Final prompt set, in order:

1. Use case: precise-object-edit. Edit target: the attached Aether Astryx LIGHT app icon. Make just one tiny color correction: all dark-gray strokes of the small robot / Godot face emblem in the lower-right folded corner must become flat solid PURE BLACK, exact RGB(0,0,0), #000000. This includes the outer head outline, both eye rings, vertical nose and bottom mouth/jaw lines. Keep line width, every contour and the emblem's size and location EXACTLY unchanged. Preserve the two already pure-black whale bodies, gray bellies, white eye and mouth cutouts, white/offwhite square tile, gray folded corner, subtle shadows and antialiased edges exactly. No reshaping, no repositioning, no new details, no text. Fully opaque square output, no transparency. Change ONLY the robot's gray strokes to pure black.

2. Use case: precise-object-edit. Edit target: the attached Aether Astryx app icon. Create its DARK MODE color variant with the exact same geometry and layout. Change the entire white/offwhite background tile AND all outer canvas corners to solid PURE BLACK #000000. Change only the black upper bodies of BOTH whales to solid PURE WHITE #FFFFFF, and their white eye and mouth cutouts to pure black. Retain the gray lower bellies and their exact shapes, with a neutral medium gray that reads clearly on black. Preserve the exact whale silhouettes, fins, tails, proportions, positions, facial expressions, and all spacing. IMPORTANT: the lower-right folded corner stays the SAME LIGHT GRAY, and its robot / Godot emblem keeps its existing PURE BLACK #000000 linework (outer contour, eyes, nose and mouth), unchanged. Keep the folded corner's original shape and position. Use clean antialiased edges and very restrained existing relief; do not add halos or glow. This is a color-only sibling of the light icon, not a redesign. No new elements, no text, no texture/noise inside solid black or white fills. Fully opaque square output, no transparency.

Run `godot --headless --script tools/generate_app_icons.gd` from the repository
root to regenerate both variants' platform sizes. Packaging retains the classic
tile's alpha mask for desktop/in-app use and emits opaque Apple mobile icons and
Android adaptive layers. No generation service is needed at build time.

- iOS: the primary icon is Astryx Light, with `Classic` and `AstryxDark` registered
  for **both** iPhone and iPad. `tools/stage_app_icons.py` adds their images to the
  exported Xcode project's resources. UIKit's public
  [alternate icon API](https://developer.apple.com/documentation/uikit/uiapplication/setalternateiconname(_:completionhandler:))
  owns the system notification shown when the icon changes.
- Android: retain `GodotAppLauncher` as the primary alias for upgrade continuity,
  add `AetherClassicLauncher` and `AetherAstryxDarkLauncher`, and switch aliases
  with `DONT_KILL_APP`. Android 13+ changes them atomically. Older versions enable
  the destination before disabling the previous aliases. Recents receives the
  corresponding task icon. Launcher refresh timing is OS-owned; Android's
  application-info icon stays primary.
- macOS: update the running Dock / app-switcher icon. Finder keeps the default
  Astryx Light bundle icon: custom-icon metadata adds a resource fork / FinderInfo,
  which fails strict code-signing validation. The signed bundle stays immutable.
- Other desktop platforms: Godot updates the window/taskbar icon. Existing
  Windows shortcuts and Linux desktop files are not rewritten.

Editor/headless previews never change the editor application's system icon.
