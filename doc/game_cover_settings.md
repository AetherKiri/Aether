# Per-game covers

Explicitly chosen covers are normalized to PNG in the game directory, alongside
`aether_config.json`. Archive library entries use their containing directory.
The filename includes the image's content hash, so selecting the same image
reuses the existing file without overwriting unrelated artwork.

```json
{
  "cover": {
    "path": "aether-cover-<content-hash>.png",
    "source": "vndb",
    "vndb_id": "v34"
  }
}
```

`path` is relative to the game directory. `source` is `local`, `photos` or `vndb`;
`vndb_id` is empty for local files and photos. The writer preserves other keys,
including `rendering` and `text`, and replaces the JSON atomically after the
image is saved. If the configuration cannot be saved, a newly created image is
removed and the previous cover remains selected. Malformed configuration is
never replaced silently.

The per-game record takes precedence over the legacy library/cover index,
including after moving or reimporting a directory. Clear saves an empty path
and leaves the image file intact. An explicit selection or Clear also suppresses
automatic VNDB recognition; an already running automatic request cannot replace
the selected cover. Games without a cover record retain legacy discovery.

The Astryx source dialog offers Local files and VNDB on desktop. Photos is
visible only on iOS and Android and uses their native photo pickers. Imported
photos are copied from the granted selection, normalized for orientation and
bounded to 4096 pixels before becoming a game cover. No whole-library access is
needed. Native-picker device behavior still requires iOS/Android device tests;
the desktop UI tests simulate their availability without accessing user photos.

VNDB is queried only after Search. Before that, the result area is blank. Results
without cover images are excluded; each row loads its thumbnail. Selecting a row
downloads and validates the full image before saving. Failed or cancelled
requests do not alter the game, and late replies after dismissal are ignored.

The React reference uses the original Astryx components and real VNDB requests,
but stores selected covers in memory; it does not write a local game directory.
