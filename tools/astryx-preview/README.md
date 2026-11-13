# Aether Astryx reference

This is a React reference for the optional native Godot shell. It imports the
original local `@astryxdesign/core` components and Neutral theme from the sibling
`astryx` checkout. It does not reproduce those controls with application CSS.

## Run

Use Node 22.12+ with the Astryx checkout at `../../../astryx` relative to this
directory. That checkout must have its dependencies and theme build available.
The reference was verified with Astryx 0.7.12 at commit
`c28d2864901161b9c3d23adf87f3d886a874eefb`. To prepare that sibling checkout,
run from the Aether repository root:

```sh
git clone https://github.com/meta/astryx.git ../astryx
git -C ../astryx checkout c28d2864901161b9c3d23adf87f3d886a874eefb
pnpm --dir ../astryx install --frozen-lockfile
pnpm --dir ../astryx --filter @astryxdesign/build build
pnpm --dir ../astryx --filter @astryxdesign/core build
pnpm --dir ../astryx --filter @astryxdesign/theme-neutral build
```

Use the pnpm version declared in Astryx's `packageManager`. Then run in
`tools/astryx-preview`:

```sh
npm ci --ignore-scripts
npm run dev
```

Open <http://127.0.0.1:8766/>. The toolbar switches between iPhone 393 × 852, iPad 834 × 1194 portrait,
and iPad 1194 × 834 landscape viewports. These are browser viewport comparisons;
native touch input and safe areas also require device validation.

`npm run build` typechecks and builds both the preview frame and React app.
`npm run tokens` exports the original Neutral light/dark semantic colors to
`apps/godot_app/assets/ui/astryx/tokens.json` and the preloaded `tokens.gd`. CSS in `src/preview.css` only handles
fonts, viewport sizing, and media geometry. Astryx's Vite plugin compiles the
library source and its own component styles.
The Vite plugin identifies the linked `astryx/packages/` source as library CSS,
so Neutral's component overrides retain their intended cascade priority.

## Reference compositions

- Settings: Astryx `pages/settings-sidebar/page.tsx`, with the template's icon
  category sidebar, a single column of setting rows, current-value summaries,
  and inline Edit links revealing original Selector/SegmentedControl/Slider
  controls. Switch labels sit on the left with the switch on the right.
  Category buttons have 8 pt gaps, keeping adjacent selected and hovered
  backgrounds visibly separate.
  At 768 pt of available content width or less (after the global app rail),
  categories and detail become separate screens with a back arrow. Resizing
  preserves the selected section, open editor, and unsaved draft. Large iPad
  portrait retains two panes; smaller iPads use the same drill-down as phones.
  Save/Cancel appear only while dirty, inside the content pane or below the
  narrow category menu. Search is intentionally absent.
  Saving uses the original Toast/ToastViewport: a horizontal, dismissible
  notification at the bottom right, with a 400 pt maximum width and 16 pt
  gutters. The phone viewport inset follows the measured bottom navigation.
  Godot matches this composition, keeps short CJK messages on one line, wraps
  longer messages, and pauses the five-second dismissal timer on hover/focus.
  Custom enhancement uses numbered algorithm rows with 16 pt gaps, separate
  Add/Remove actions, and full-width selectors below the row heading on phones.
  About rows place titles and descriptions on the left and version values,
  links, or switches on the right. Native purchase rows reuse the host's action
  buttons, preserving their availability, prices, and callbacks.
  Diagnostics omits the developer-only Scene Test launcher.
- Game details: Astryx ProductDetail composition, with a hero frame that follows
  the source image ratio and fills the gallery width up to the initial viewport
  height limit. Artwork has no backing panel, letterboxing, or forced 4:5 crop.
  A visible left arrow returns to the library. Optional selectable thumbnails,
  full-width actions, and multiple collapsibles complete the composition.
  The title has no file-type subtitle. Assigned covers add a soft, blurred
  top backdrop fading into the theme surface, matching the classic image
  shader in Godot. Setting or clearing a cover updates the backdrop immediately.
  Collapsible titles and their revealed content share the same leading edge,
  including native hover and pressed states.
  Game information starts with Game name, followed by the current name on the
  left and Edit on the right. Editing hides that link and reveals an inline
  name input, with a primary Save button and ghost Cancel button below it.
  Save refreshes the title without changing the game path or cover association;
  Cancel restores the saved name, and empty names cannot be saved.
  The launch-file name remains on the left with Set on the right; configured
  launch files also retain their Reset action. Delete Game is a full-width
  destructive button at the bottom, using the existing platform-specific
  removal confirmation. The separate Manage Game button/menu is removed.
  Graphics & rendering replaces Compatibility. Its three primary choices
  (scaling, output resolution, enhancement) reuse the global catalog plus
  Use app settings. Enhancement includes all eight presets and the same
  custom-chain editor. Each row uses the same inline Save/Cancel pattern as
  Game name. Enhancement kind, preset and custom steps form one edit group.
  Native changes stay in a draft until Save writes the game's
  `aether_config.json`; Cancel leaves the file untouched. Failed saves retain
  the editor and draft with an inline error. Rotation preserves drafts; leaving
  details, switching games or closing the section discards them. Empty strings
  inherit current app preferences at launch without changing the global draft. See
  [per-game rendering settings](../../doc/game_render_settings.md) for the schema
  and launch/validation behavior. React stores per-game fixture choices only
  in memory, so navigation preserves them and reload resets them.
  Runtime-specific encoding controls remain in Graphics & rendering. React's
  inline name editor and deletion dialog update only in-memory fixtures,
  recoverable by reload.
  The final Cover section starts with a single-line file location,
  then a full-width Set Cover button and a separate full-width Clear Cover
  button. Clear appears only with an assigned cover and uses the original
  Neutral destructive colors; Set uses the primary style. Long paths truncate
  with a full-path tooltip. Clearing a cover removes its association and refreshes the
  artwork without deleting the source image. Set Cover first opens the original
  Dialog with Local files and VNDB search. Photos is shown only on iOS/Android;
  the viewport wrapper simulates iOS, while a direct `/app.html` visit detects
  the host platform (`?platform=ios|android|macos` can override it for comparison).
  VNDB starts with an empty result area, then shows thumbnail/title cards after
  an explicit search. Choosing a result downloads the full cover; cancelling
  or failing leaves the previous image intact. The React preview downloads into
  memory only, whereas Godot saves the image and a relative path in the game's
  `aether_config.json`. Native Photos uses PHPicker on iOS and Android's Photo
  Picker, importing only the selected image. See
  [cover persistence](../../doc/game_cover_settings.md).
- Library: original ClickableCard, Grid, TextInput, and TabList.
  The header's original SegmentedControl switches between cards and original
  List/ListItem rows with cover thumbnails. The choice persists separately
  from settings and preserves the current search/filter in both presenters.
  Both visible display-switch buttons and the Import action are 44 pt tall
  and vertically aligned; the segmented container has no inset padding.
  Cards and list rows show cumulative play duration and the last launch's
  local date/time below the title. Unplayed games show zero time and an
  explicit Not started yet state. Metadata can wrap on narrow viewports;
  native row/card height follows its contents. React fixtures include both
  played and unplayed games, with the Recent filter using those records.
- Phone navigation: four original Astryx IconButtons in equal-width slots, with
  outline/filled Heroicons, accessible labels, and safe-area padding. No visible
  labels or tab underlines. iPad retains the SideNav composition.
  Its App icon toggles the original collapsible SideNav/SideNavHeading between
  the 48 pt icon rail and a 260 pt sidebar with full navigation labels. Godot
  mirrors the width transition and moves the page content with it. Pointer
  activation leaves no focus outline; keyboard activation retains a neutral
  focus indicator.
- Video/Flash: original List/ListItem and Breadcrumbs, with folders, files,
  nested paths, recursive search, and an empty folder fixture.
  Folder navigation uses clickable ancestors and a current-location label;
  there is no separate Back button or redundant breadcrumb at the library root.
  The trailing open/play and delete IconButtons are aligned 44 pt squares.
  Delete opens the existing removal confirmation directly. Native removal
  semantics are unchanged; the preview removes only its in-memory fixture.
- Controls: original SegmentedControl, Selector, Switch, Slider, Button,
  Dialog, and DialogHeader. Settings use controlled draft state and an
  explicit save/discard dialog.

The only app routes are games, videos, Flash, and settings. Themes are Light and
Dark. Sample game covers include original portrait and landscape SVG fixtures.
Game launch, import, and
media playback show interaction notices here; the Godot presenter connects the
existing application operations. The media dialog previews player controls and
does not claim to play a real video file.

## Native integration

`scripts/ui/astryx/shell_interface.gd` owns the opt-in preference independently
of classic UI settings. The new view is a sibling presenter inside the existing
safe-area shell. Two small hooks in `main.gd` mount the classic settings switch
and pass unsaved-settings navigation through the new presenter. Existing game
and file-library models, runtime launch, imports, and settings persistence remain
the action endpoints.

Godot uses native Controls; it does not execute the React library. Its semantic
colors are exported from the original theme, and its layout and interaction
behavior are compared to this React reference. Touch controls have 44 pt targets.
The announcement header uses the actual app icon. Other inherited modal badges
receive matching surface/icon colors so their icons remain visible in both themes.
Native text pairs Figtree with the bundled full Noto Sans CJK and symbol fonts;
regular and emphasized text use matching fallback chains. The small UI-only
font subset is unsuitable for arbitrary game titles.
CJK text uses explicit 2x sampling so small glyphs remain intact after changing
the interface language.
Real games currently expose one cover, so their details omit the fixture-only
thumbnail gallery. Native select popups and animations are platform renderings,
not browser DOM controls.

Run the integration test with a Godot binary and this repository as the working
directory:

```sh
godot --headless --path apps/godot_app --script res://tests/astryx_shell_test.gd
godot --headless --path apps/godot_app --script res://tests/astryx_typography_test.gd
godot --headless --path apps/godot_app --script res://tests/game_render_config_test.gd
godot --headless --path apps/godot_app --script res://tests/game_text_config_test.gd
godot --headless --path apps/godot_app --script res://tests/game_cover_config_test.gd
godot --headless --path apps/godot_app --script res://tests/cover_source_test.gd
```

The test checks landscape and both large/small iPad portrait layouts, phone
category navigation, inline edits, draft preservation across rotation,
custom-chain selection/add/remove/cancel, About action alignment and purchase
button state, save/discard, and the existing library/detail interactions.
Language-save checks cover Chinese, Japanese and English notification layout,
Light/Dark, phone navigation clearance, replacement, manual and timed dismissal.
Media checks cover ancestor/root navigation, search reset, aligned action targets,
and opening/cancelling removal without triggering playback or changing a source file.
Detail checks cover launch/cover action placement, long paths, primary/clear
colors, picker delegation, the clear/reset state, per-game rendering JSON writes,
inheritance, presets, custom steps and isolation from other games/global drafts.
Inline detail editors verify hidden Edit links, Save/Cancel placement, pending
changes without file writes, cancellation, failure recovery and draft preservation
across rotation. Game-name checks include empty names and unchanged game identity.
Text editors cover engine-specific encodings, font selection/preview, delayed
picker cancellation, portable font import on Save, resetting to defaults and
the native Unicode boundary in EntisGLS. The React fixtures include ONScripter
Yuri, YU-RIS and EntisGLS; their text settings stay in memory. Native persistence
and launch behavior are described in `doc/game_text_settings.md`.
Cover-source checks cover desktop/mobile availability, phone/tablet rotation,
Light/Dark, initial blank results, thumbnails, explicit selection, download/save
failure, retry and late cancellation. The persistence test covers moved folders,
reimport, unrelated configuration keys, repeat selections, Clear and failed
config writes. Set `AETHERKIRI_COVER_LIVE=1` for an optional real VNDB search and
download using a temporary game directory; offline tests use request fixtures.
Shared cover-index writes are intercepted by the test host;
the presenter test does not modify the user's library. It uses temporary
preferences and media files. To capture its rendered
layouts, omit `--headless` and set `AETHERKIRI_ASTRYX_CAPTURE_DIR` to an existing
output directory.

Astryx templates and theme are MIT licensed; see `ASTRYX-LICENSE`. Figtree's OFL
license is in `apps/godot_app/assets/fonts/Figtree-OFL.txt`.
