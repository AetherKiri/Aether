# SystemNNN Emberfall: render and story presentation source reading

## Scope, revision and evidence authority

This is an incremental source-reading supplement to [EMBERFALL-AUDIT.md](<../../EMBERFALL-AUDIT.md>), not a whole-core audit or a replacement for the separate Aether adapter audit. Source identity: Emberfall **f52d77f**, Aether **81c09626** at inspection. No implementation files changed; no tests were executed or rerun. Existing normal/sanitizer/Godot results are not new evidence from this reading. No global pixel parity, supplied-game binary parity, complete game compatibility, or exploitability claim follows from reading a dispatch branch.

F = entire file read through EOF; P = selected ranges only; U = not read in this incremental pass. F denotes reading coverage, not correctness, exhaustive parameter validation, or verification of the historical source comments. Full render include/src inventory was enumerated: two public headers, two private headers, four implementation files. In particular the formerly partial effects implementation was read **1–4432 through EOF**, not merely its dispatch table.

## Coverage ledger

| Status | File | Read boundary |
|---|---|---|
| F | [render.hpp](<../packages/SystemNNN-Emberfall/platform/render/include/emberfall/render.hpp>) | 1–39, EOF read |
| F | [layers.hpp](<../packages/SystemNNN-Emberfall/platform/render/include/emberfall/layers.hpp>) | 1–209, EOF read |
| F | [render.cpp](<../packages/SystemNNN-Emberfall/platform/render/src/render.cpp>) | 1–46, EOF read |
| F | [layers.cpp](<../packages/SystemNNN-Emberfall/platform/render/src/layers.cpp>) | 1–1213, EOF read |
| F | [effects.hpp](<../packages/SystemNNN-Emberfall/platform/render/src/effects.hpp>) | 1–94, EOF read |
| F | [effects.cpp](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp>) | 1–4432, EOF read |
| F | [wipes.hpp](<../packages/SystemNNN-Emberfall/platform/render/src/wipes.hpp>) | 1–70, EOF read |
| F | [wipes.cpp](<../packages/SystemNNN-Emberfall/platform/render/src/wipes.cpp>) | 1–758, EOF read |
| F | [CMakeLists.txt](<../packages/SystemNNN-Emberfall/platform/render/CMakeLists.txt>) | 1–23, EOF read |
| F | [story_compositor.hpp](<../packages/SystemNNN-Emberfall/platform/scene/include/emberfall/story_compositor.hpp>) | 1–104, EOF read |
| F | [story_compositor.cpp](<../packages/SystemNNN-Emberfall/platform/scene/src/story_compositor.cpp>) | 1–218, EOF read |
| F | [game_session.hpp](<../packages/SystemNNN-Emberfall/platform/scene/include/emberfall/game_session.hpp>) | 1–375, EOF read |
| P | [game_session.cpp](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp>) | Presentation/timing/command/snapshot excerpts, including 1490–1589, 3701–3880, 5401–5760, 5850–5949, 6055–6121, 6221–6414; other earlier targeted excerpts do not amount to a full read |
| U | [render_tests.cpp](<../packages/SystemNNN-Emberfall/platform/render/tests/render_tests.cpp>) | Not read or run in this pass |
| P | [systemnnn_runtime_provider.cpp](<../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp>) | Presentation, tick, immutable frame description/read/serial paths; not a complete adapter audit |
| P | [main.gd](<../apps/godot_app/scripts/main.gd>) | Tick/update/presentation excerpts, chiefly 15955–16114 and 17260–17324; not a whole GUI read |
| P | [rfvp_runtime_provider.cpp](<../bridge/rfvp_runtime/src/rfvp_runtime_provider.cpp>) | 190–244 only, as a serial/read convention comparison |

Other scene files and all core files retain their prior audit status; none are promoted to F by transitive includes or by this document. Render build configuration was also read: static render library, C++17, warnings-as-errors on GNU/Clang, optional ASan/UBSan, one render CTest declaration. Build/test declarations are not execution evidence.

## Render model and composition

- [render.hpp:8](<../packages/SystemNNN-Emberfall/platform/render/include/emberfall/render.hpp#L8>) sets max dimension 8192 and max pixels 16 Mi. The low-level blit accepts **straight, top-left RGBA** and writes an **opaque, top-left RGB** destination. It validates before writes, clips destination edges, does not scale, does not permit aliasing, and requires caller serialization.
- Two explicitly named blend profiles, Source32Mmx and Source64Cpp, model different upstream source branches; the header explicitly disclaims identifying the supplied game's binary. Do not substitute generic Android SRC_OVER or infer that the two profiles give interchangeable edge rounding.
- Layers has 32 storage slots, source/from/to rectangles, per-effect parameters/count/state, hidden/enabled/opaque flags, and a separately configured active layer count. It validates texture/canvas and message-plane dimensions and tracks redraw/revision state.
- Message planes are **premultiplied RGBA**, logical-resolution, unlike texture RGBA. Composition separates clean scene/message/backdrop/filter order from display-only floating material. Floating RGBA is added in StoryCompositor after obtaining the clean frame; it does not become the authoritative save/overlap image merely because it is on screen.
- Layers retains prepared overlap source, target, decorated display endpoint, saved screen, scene/story output and last acknowledged presentation as distinct objects. [layers.cpp:1198](<../packages/SystemNNN-Emberfall/platform/render/src/layers.cpp#L1198>) copies the clean surface into presented state only on after_present. Surface access/rendering alone is not that acknowledgment.
- The full layers implementation read includes chart primitives, saved/background drawing, texture/animation paths, overlap capture/finish/resume, dirty flags, effect setup/advance, snapshots and surface accessors; this does not extend coverage to chart model or save parser dependencies.

## Effect support: exact dispatch inventory

Support means a recognized branch with the implementation described below; it **does not** mean every argument vector, asset combination or source-edition variant produces an image. Missing texture, missing alpha mask, unavailable animation/mesh, unsupported parameter modes, and source-like no-op states can return without drawing. Unknown effects can fall back to basic alpha rendering with a warning in GameSession ([game_session.cpp:3730](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L3730>)).

### Basic layer dispatch

The basic recognized set is **-1, 0, 1, 2, 8, 9, 10, 11, 17, 52, 54, 61, 65, 66, 73, 99, 100** ([layers.cpp:223](<../packages/SystemNNN-Emberfall/platform/render/src/layers.cpp#L223>)). These are distinct from effects::known. Basic setup preserves explicitly supplied zeroes while filling omitted defaults before fixed-record save padding. Animated-basic classification is **9, 10, 11, 17, 52, 61, 65, 99, 100**. Recognition is not a continuous interval and should not be replaced by an upper-bound check.

### Native-effect recognition sets

[effects.cpp:3572](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L3572>):

- known_v5: **13, 20, 22, 23, 24, 29, 31, 37, 40, 43, 50, 55, 56, 60, 62, 64, 67, 71, 74, 77, 81, 86, 94, 102, 106, 109, 110, 112, 119, 122, 123, 124, 125, 126, 127, 128, 129, 131, 136, 138, 139, 140**.
- Additional known switch cases: **12, 14, 15, 18, 19, 26, 27, 28, 32, 33, 36, 39, 42, 48, 51, 57, 59, 63, 68, 69, 70, 72, 75, 76, 78, 79, 80, 82, 83, 84, 85, 90, 91, 92, 93, 96, 97, 98, 101, 103, 104, 105, 107, 108, 111, 120, 121, 130, 132, 133, 137**.
- Geometry set additionally recognized: **87–89, 95, 113–118** ([effects.cpp:1050](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L1050>)).
- Continuous set: **12, 13, 14, 15, 24, 26, 29, 42, 51, 55, 56, 57, 71, 83, 85, 91, 92, 93, 96, 102, 106, 109, 132, 138** ([effects.cpp:3591](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L3591>)). Continuous is an independent classification, not all known effects.

### Native draw families

Source branch names below are implementation labels, not a claim to have recovered game-author vocabulary. Dispatch source: [effects.cpp:4222](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L4222>) through EOF.

| IDs | Dispatch / operation |
|---|---|
| 87–89, 95, 113–118 | geometry path |
| 0 | ordinary texture drawing |
| 12, 14, 57 | ordinary + falling_sprites |
| 15 / 18 / 26 / 28 / 32 / 33 | ordinary + sun_rays / shake / remembered_edges / circular_mask / melt_down / relief |
| 19 | buffer_animation |
| 27, 108 | wandering_sprites |
| 36 / 39 / 42 / 48 / 51 | stretch / scrolling_picture / sparkles / boss_death / sun_flare; 39/42/51 first draw ordinary |
| 59 / 60 / 101 | simple_layer_wipe / mask_wipe / moving_mask_wipe, with layer/saved-screen inputs |
| 63 / 68 / 69 / 70 / 72 | sprite_animation / curtain / ripple / petals / camouflage |
| 75 / 76 / 78, 121 / 79 / 80 | once / slash_blur / dual_mask / full_animation / staff_roll |
| 82 / 83 / 84 / 85 | clouds / shore / fusuma / speed_streaks |
| 90 / 91 / 92 / 93 / 96 / 97 / 98 | character_flash / waterfall / sway / grass / rainbow / bath_window / face_animation |
| 103 / 104 / 105 / 107 / 111 | target (+ordinary) / spiral_sprites / movie_warp / character_raster / swimming_fish |
| 120 / 130 / 132 / 133 / 137 | color_balance / psychedelic / chara_bure / sentence / external_animation |
| 81 / 67 / 55 / 109 / 23 / 22 / 24 / 86 | shards / perspective / old_film / old_lamp / raster / kagerou / water / zantetsu |
| 123 / 37, 122 / 110 / 71 / 13 | mask_appear / zoom_in / chara_ghost / old_fireflies / rain |
| 106 / 138 / 29 / 56 / 102 | chara_noise / fireflies / suna / rain2 / rain4 |
| 140 / 64 / 40 / 112 / 139 / 136 | turn_new / turn / change / metal / chara_mosaic / taclip |
| 77 / 125, 126 / 74 | blur_screen_picture / blur_character (variant flags) / bura |
| 20 / 43 / 50 / 31 | screen RGB add / sampled block mosaic / row-gradient RGB add / contrast-invert style channel transform |
| 128, 129 / 124, 127 / 131 | screen grey or tint / character grey or sepia / masked character additive/subtractive blend |
| 62, 119 / 94 | cubic or quadratic spline placement / tiled scrolling offsets |

Ordinary drawing precedes the later post-processing chain for **13,20,22,23,24,29,31,43,50,55,71,74,128,129**. Setup pads known parameters to at least 36 slots, uses slot-seeded deterministic effect state, and supplies/clamps defaults selectively. Particle/noise/rain/mesh setup and advance were read, including the helper bodies before the tables; the tables alone would not establish those behaviors. Fragment effect 81's optional external mesh is supplied by the scene asset path, not synthesized from this audit. Face, full/external animation, masks, saved screens and other-slot dependencies are integration prerequisites, not implicit assets guaranteed by recognition.

## Wipes: exact support and routing

[wipes.cpp:702](<../packages/SystemNNN-Emberfall/platform/render/src/wipes.cpp#L702>) declares **0–95 inclusive** supported. Output/before/after dimensions and RGB lengths are checked before dispatch. Endpoint copies are explicit: frame 0 returns before unless already at/after duration; frame >= frames returns after, including zero-duration endpoint. Every nonzero in-range type has a specific family; **0 uses the final crossfade branch**. Out-of-range calls to draw_wipe also reach that fallback, while supports_wipe rejects them and Layers/GameSession can warn.

| Type | Family |
|---|---|
| 0 | crossfade |
| 1–2 / 3 / 4–5 / 6–8 / 9 | curtain / zebra / slide / circle / clock |
| 10–17 / 18–21 / 22 / 23,73 | move / door / paint_over / gravity |
| 24–25 / 26–27 / 28–29 / 30–31 | gaza / raster / star / heart |
| 32–33,78–79 / 34–35 / 36–37 / 38 / 39 / 40 / 41 | turning_star / shatter / beach / mosaic / random_strip / add / turn_page |
| 42–47 / 48–53 / 54–59 / 60 | blinds / width-variant gaza / width-variant beach / multiply |
| 61–64 / 65–68 / 69–72 / 74–77 | push / diagonal / slots / alternate slots |
| 80–83 / 84–87 / 88–93 / 94–95 | zoom / center / pointed_edge / double_pointed_edge |

All helper bodies in the wipe file were read; no golden-image comparison or assertion that all families match every historical executable was performed.

## Story compositor, timing and acknowledgment

1. [story_compositor.hpp:14](<../packages/SystemNNN-Emberfall/platform/scene/include/emberfall/story_compositor.hpp#L14>) matches **PlaneKey fields 0–4 only**; field 5 carries UI state such as bridge text-complete bit 17. Expected keys include wait type, dialogue sequence when relevant, window visibility, DRAW-message class and choice identity ([game_session.cpp:6068](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L6068>)). UI decorative sessions do not request story planes.
2. Mailbox push copies premultiplied logical-resolution RGBA with stride/dimension checks; snapshots keep shared immutable front ownership while spare buffers are reused under mutex. The caller still owns readable source memory during push; the pointer interface does not carry a byte-span length.
3. [story_compositor.cpp:137](<../packages/SystemNNN-Emberfall/platform/scene/src/story_compositor.cpp#L137>) skips the first two missing/mismatched-plane ticks; **after that it logs once and continues retaining the last complete frame indefinitely until a matching plane arrives**. The threshold does not authorize a partial frame, automatic successful submission, or script ack. This detail supersedes any informal reading of “two-tick fallback” as a forced new frame.
4. waiting_for_draw requires pending retry + attached mailbox + DRAW + needs_message_plane. It lets hosts avoid consuming a short DRAW while UI is missing. Submit failure sets retry without ack; success alone calls GameSession::after_present. Override surfaces do not ack the underlying game. Display-only floating overlay is composed after the clean frame and before submit.
5. [game_session.cpp:1545](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L1545>) repays animation pacing debt per wait: DRAW/Overlap bound requested ticks by remaining wait, Choice clears debt, no-skip-frame limits repayment, other waits clear debt. FrameTiming separates wall elapsed milliseconds from animation budget; choice timeout and speaking timers use elapsed, effect ticks use animation/period with remainder. Hosts must not blindly substitute animation time for all wall-clock consumers.
6. [game_session.cpp:5542](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L5542>) consumes DRAW time, returns while remaining unless advance/film-skip applies; the VM yields at each DRAW ([game_session.cpp:5599](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L5599>)). Normal overlap completion returns the endpoint before the next script command; film-skip deliberately relaxes it. There is not evidence that one ordinary foreground tick executes several separate DRAW yields.
7. Decorative UI background execution differs: [game_session.cpp:6249](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L6249>) steps script first, restarts on END if looping, then repays within the current wait and consumes new-wait time on entry. It is not interchangeable with foreground stepping. GameSession::after_present also commits presented thumbnails and can finish a native panel ([game_session.cpp:6089](<../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L6089>)), so premature or missing ack affects more than redraw state.

## Bounded findings and follow-up risks

### R1 — native snapshot loader does not revalidate all effect invariants

**Source-supported hardening issue; no current malicious Aether PC-save exploit claimed.** [layers.cpp:1063](<../packages/SystemNNN-Emberfall/platform/render/src/layers.cpp#L1063>) loads raw native snapshot effect parameters/state rather than rerunning configure for already-known stateful effects. It checks name/parameter length, state presence, minimum 36 parameters, and nonempty raster/noise dimensions; it does not enforce all per-effect constructor invariants.

Minimal direct source proof candidates (not executed):

- **Effect 56:** configuration clamps p[3] to 1–4 and p[7] >= 1 ([effects.cpp:3914](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L3914>)); State::rain is exactly four entries ([effects.hpp:58](<../packages/SystemNNN-Emberfall/platform/render/src/effects.hpp#L58>)). A structurally valid snapshot with known effect 56, state present, 36 parameters, valid texture and **p[3]=5** passes the shown loader layer checks ([layers.cpp:1103](<../packages/SystemNNN-Emberfall/platform/render/src/layers.cpp#L1103>)), then rain2 indexes rain[4] at [effects.cpp:3485](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L3485>); advance similarly uses the unchecked count at [effects.cpp:4162](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L4162>). A zero p[7] also violates a later modulo precondition when jitter is positive.
- **Effect 106:** normal configure fills raster via noise_raster ([effects.cpp:4015](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L4015>)). Loader permits an **empty** raster because it only rejects a nonempty raster of the wrong height ([layers.cpp:1117](<../packages/SystemNNN-Emberfall/platform/render/src/layers.cpp#L1117>)). With a visible masked texture, chara_noise indexes raster[y] without an empty check ([effects.cpp:3347](<../packages/SystemNNN-Emberfall/platform/render/src/effects.cpp#L3347>)). Rendering immediately after restore is the relevant sequence; advance may rebuild some state and is not required before surface access.

Follow-up: validate per-effect restored parameters and state sizes/ranges before committing a native snapshot; preserve valid serialized stochastic state rather than blindly rerunning configure. Add bounded negative tests for these direct native snapshot cases under sanitizers only in a separately authorized fix task. Existing bridge save path uses export_presented_pc_save/load_pc_save_candidate ([systemnnn_runtime_provider.cpp:210](<../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L210>)); it is not proven to expose arbitrary Layers native snapshots. Internal backlog snapshots, if generated only by valid current state, are not thereby an adversarial input. No upstream edits made under this pinned audit.

### R2 — CPU publication acknowledgment is not physical-display acknowledgment

**Boundary limitation / conditional host-contract risk, not a demonstrated normal GUI regression.** In [systemnnn_runtime_provider.cpp:310](<../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L310>), publish constructs a new RGBA Frame with alpha255 and serial, then retains it. StoryCompositor submit returns true after that CPU publication ([systemnnn_runtime_provider.cpp:359](<../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L359>)), authorizing clean-frame/thumbnail/native-panel ack. describe retains a selected shared Frame; read_frame copies that selected immutable snapshot and updates delivered serial ([systemnnn_runtime_provider.cpp:554](<../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L554>)). get_frame_rendered_flag compares published vs delivered serial; it is not a monitor/display callback.

The normal host loop calls one tick then frame_rendered_this_tick/_update_frame ([main.gd:16043](<../apps/godot_app/scripts/main.gd#L16043>) and [main.gd:16104](<../apps/godot_app/scripts/main.gd#L16104>)); _update_frame uploads/assigns a texture ([main.gd:17269](<../apps/godot_app/scripts/main.gd#L17269>)). This is a viable latest-frame CPU-sink contract. It does not prove scanout, GPU completion, or that the user actually saw the frame. The inspected RFVP wrapper also tracks CPU read serial separately ([rfvp_runtime_provider.cpp:208](<../bridge/rfvp_runtime/src/rfvp_runtime_provider.cpp#L208>)); that comparison does not establish every provider's internal present convention.

If a host batches multiple ticks without reading, subsequent short DRAWs can replace an undelivered retained frame; mailbox readiness gating does not enforce delivered-serial backpressure. This is a source-derived scheduling scenario, not an executed failure. Tests that intentionally tick without reading rely on such forward progress. GUI present-hold/black-frame suppression paths further show that upload/read and actual viewport assignment are not identical concepts; applicability of those helpers to SystemNNN was not fully audited. Do **not** simply gate all ticking on host delivery: it changes tick-only/startup behavior and still cannot guarantee physical display. Specify whether the desired contract is latest-frame CPU sink or mandatory per-DRAW delivery, then test that contract separately. No runtime fix requested or made.

### R3 — unsupported variants, premultiplication and clean/display planes remain integration obligations

The recognized-ID lists are not complete input validators. Preserve premultiplied message/floating planes vs straight texture RGBA, fixed logical dimensions, layer/saved-screen relationships, animation providers and required masks. Missing prerequisites may silently draw nothing inside recognized branches, whereas unsupported IDs are warning/fallback paths. Mixing Pass-D display overlays into the authoritative clean capture can pollute subsequent PREPARE/overlap or save thumbnails. This is a concrete contract risk, not a new observed adapter defect; the separate adapter audit owns its implementation verification.

## Completion boundary

Requested platform/render include/src files and StoryCompositor header/implementation are now F, including all 4432 effect lines and 758 wipe lines. Presentation-related GameSession is deliberately P. Remaining work belongs to a separately scoped core/scene/save/dependency read or contract-specific tests; current source reading and earlier runtime smoke are not substituted for full-core understanding or pixel-global parity.
