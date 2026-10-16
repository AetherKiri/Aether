# Bink 2 decoder backport

`bink2-decoder.patch` adds the Bink 2 video decoder to this FFmpeg port. The
decoder comes from Paul B Mahol's Librempeg commit
`1c54cb76bb29e754df25732952e8a5f2d82dade4` with decoder files pinned to
`7ac786568b26ca7e0bf77c44d46d827e9d57af0d` (VLC init, chroma motion
compensation, dimension init, DC clipping and block flag fixes included).
The same patch was validated against FFmpeg 7.1.2 in the AetherMAGES host
package; this copy is adapted to 8.1.2 (the codec ID and descriptor entries
are appended after the 8.1-era video codec block instead of after LEAD).

Shared-library ABI and existing codec IDs are preserved; the Bink 2 video ID
is appended to the video range. The demuxer maps supported Bink 2 tags
(`KB2a..KB2n`) to the new decoder. Bink audio v2/`n` support is deliberately
excluded; MO8 PC `KB2j` movies use the existing Bink DCT audio decoder.

The decoder sources are GPL-3.0-or-later, so the `bink2` feature enables
`--enable-gpl --enable-version3` and produces GPL-3-or-later FFmpeg
libraries; the installed copyright file follows configure's license report.
Without the feature the decoder is disabled (`--disable-decoder=bink2`) and
the build stays LGPL. No game assets are included.

Aether requests this software decoder on all native platforms so MO8 movies
use the same decoder on Linux, macOS, iOS and Android. The Web build excludes
the embedded MAGES runtime and does not request this feature.
