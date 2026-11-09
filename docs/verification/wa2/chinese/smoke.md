# Phase3 Chinese Godot smoke — PASS after font fix

The missing Chinese body glyph issue is CLOSED by fresh actual-frame inspection. Re-read the new [report](../phase3-cn-smoke/report.json), [run log](../phase3-cn-smoke.log), and all9capture JSON files; opened all9new1280×720PNGs individually with read_image. The settled and final images now clearly display the complete sentence「终于，还是下起来了。」with no square placeholders. This is scoped acceptance of this smoke sample, not a claim that every line in the overlay has been visually reviewed.

## All9fresh images actually inspected

| Capture | Actual observation |
|---|---|
| [title](../phase3-cn-smoke/title.png) | Complete street background, WHITE ALBUM2logo, four Chinese menu items and footer. No blank viewport or image placeholder. |
| [new game](../phase3-cn-smoke/new-game.png) | Near-black early story frame with small particles; runtime state establishes actual Enter-driven NEW GAME into1001. Not a settled body sample. |
| [movie before finish](../phase3-cn-smoke/movie-00-before-finish.png) | Near-black particle frame at native movie wait. Explicit headless completion acknowledgement proves protocol progression, not movie visual playback. |
| [ordinary before click](../phase3-cn-smoke/ordinary-before-click.png) | Overcast sky, particles, blue message decoration and icon strip. Chinese「啊…」and quotation marks visible. |
| [ordinary save before](../phase3-cn-smoke/ordinary-save-before.png) | Same sky/window with faint first character「终」beginning to reveal; square placeholder from prior build is gone. Full sentence not yet visible. |
| [ordinary away](../phase3-cn-smoke/ordinary-away.png) | Different airport fence/rooftop background confirms progression away from saved scene. Current body is only just revealing; not used as a complete-paragraph readability sample. |
| [ordinary load after](../phase3-cn-smoke/ordinary-load-after.png) | Restores sky/window/particles and the same faint「终」reveal frame as save-before. |
| [ordinary load settled](../phase3-cn-smoke/ordinary-load-settled.png) | After120input-free ticks, complete「终于，还是下起来了。」is legible, including「终」and「还」. No clipped glyph, square placeholder or mojibake in this sentence. |
| [final](../phase3-cn-smoke/final.png) | Same complete, readable Chinese sentence and sky/window composition as the settled capture. Final state is a story checkpoint, not an ending. |

All9metadata files identifycaptureSource=engineRGBA,renderBackend=DebugCPU. These are actual compiled-extension Godot frames read through AetherRuntimePlayer.read_frame_rgba, not SDL captures or the dummy headless viewport. The font is visually thinner/smaller than the earlier fallback rendering, but the inspected complete sentence is legible and fits the available area.

## State, save/load and silent-mode evidence

The actual report haspass=true,all13checks passing,493fixed16msframes,9captures,audioAcks=10,checkpointDifferences=[],and312active-storytextEncodingchecks. Ordinary save readiness was true atframe371without extra waiting. The title/debug state usescp932/textSource=none before story text is active; active body samples useutf-8/textSource=patch-overlay, which is the intended scoped encoding assertion.

[Save-before](../phase3-cn-smoke/ordinary-save-before.json), [load-after](../phase3-cn-smoke/ordinary-load-after.json), and [settled](../phase3-cn-smoke/ordinary-load-settled.json) retain script1001,PC1136,pageIndex0,pageText「终于，还是下起来了。」,message wait,SKIPoff and identical29globals. The strict ordinary-load comparison passes;120settling ticks also preserve the checkpoint on every tick. Save-before/load-after rawRGBAhashes match exactly:f45cc6e1e9a1fa9b018f8af04c9bd4ee7390fe40a8ca63bd5bf05838e2f4f341.

Fresh settled rawRGBA SHA256 is370b38f912b4467352f1e96c7b417252a1d1759530f7ba1fb9465d1f7536ac15. Its actualPNG attachment SHA256 is05a77bf8081b4da2b4a3f1d7beabf9960b81b6a472cd0387111eb65313b3a926. FinalPNG has the same hash. These hashes distinguish the fixed output from the historical missing-glyph image.

Final runtime haspatchOverlay=true,overlayHits=6,textEncoding=utf-8,textSource=patch-overlay,saveReady=true,audioSilent=true,pendingAudio=[],error/scriptError/providerError empty. No pendingPLAY is present in any of the9reviewed JSON snapshots; the driver rejects PLAY during the run and acknowledges known STOP/VOLUME events. The immediate load snapshot contains three STOP events; the following120ticks consume them. This establishes silent lifecycle handling, not audible sound quality.

The actual run log records ordinary-loadPASS, ordinary-load-settledPASS and text-encoding-checkedPASS; the FAIL|ERROR|MISS search returns no such matches. The configured font/patch paths are recorded in report.engineOptions. Source/control ASCII is valid data and is not treated as a translation failure. The parent identifies the private message-renderer font initialization fix as source1e04066; this reviewer independently verifies the fresh screenshots/state rather than auditing that code change.

## Historical failure retained and now closed

The previous run had correct decoded pageText「终于，还是下起来了。」but the actual settled image displayed「□于，□是下起来了。」. The missing glyphs were「终」and「还」, and the early save image showed a square as well. Those were actual body-rendering defects; font coverage statistics did not justify accepting them. Visual review was held after6of9oldPNGs and an OPEN record was written.

Old settledPNG SHA256:b7986366a9d2260f0ddf8dcfefad9b5c7da1638a625b125e4058023b83f06acf; oldrawRGBAhash:38bc283eae067876265602ae8d1afb955ea7d2ca392e31199beba762244276eb. The same output paths now contain fresh fixed captures, so the links above refer to the current result, not archived old images.

Closure is based on opening all9freshPNGs and observing the full settled sentence, not on the logical report alone. No broader route/option/font coverage claim follows from this small smoke; the fresh full-normal and other route reviews are separate evidence. One native movie wait was acknowledged headlessly; neither video visual parity nor audible output is validated here. No GD/core edits, builds or game jobs were made during this review.
