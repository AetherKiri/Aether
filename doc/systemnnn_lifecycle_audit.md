# SystemNNN independent lifecycle source audit

Audit date: 2026-11-17. Read-only production-source review; no REA, no edits to production code or existing tests, and no builds in shared build directories. Provider/presenter were being edited concurrently by another agent. All four requested implementation files were read in full: [provider](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp), [minigame binding](../bridge/systemnnn_runtime/src/systemnnn_minigame_binding.cpp), [movie](../bridge/systemnnn_runtime/src/systemnnn_movie.cpp), and [audio](../bridge/systemnnn_runtime/src/systemnnn_audio.cpp). Supporting GameSession/GameAudio/storage contracts and existing tests were inspected.

## 1. New-game chart storage changes namespace, and has no empty-writable fallback

**Severity:** release-blocking persistence defect for chart-using games.

**Original audited source:** [provider, start_story](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp) originally line 176 set chart storage only when `!writable.empty()`, to `writable/"systemnnn"/"chart"`. Original open line 494 and load line 221 instead used `writable/"systemnnn"` or `root/"sav"`.

[ChartNodeStore:28–46](../packages/SystemNNN-Emberfall/platform/scene/src/chart_node_store.hpp#L28-L46) reads and writes exactly `private_/relative`; read fallback goes to installation save data, not the sibling private namespace. Therefore nodes created in a new story are inaccessible after replacing that story through slot load/reopen. With no writable path the new-story candidate never receives a private directory at all; chart writes reject the empty directory. This is grounded in storage/path data flow, not an executed full chart fixture.

**Minimal fix:** one `chart_root()` helper returning `writable.empty() ? root/"sav" : writable/"systemnnn"`; set it on every candidate, **before** `load_pc_save_candidate`, because loading can consult chart nodes.

**Status:** relayed to parent/provider/test owners. At the 17:35 follow-up read, provider had `chart_root()` around line 153, start_story used it around line 178, and load set it on the candidate around line 219 before importing. Source fix observed at that checkpoint. The later final provider ABI regression covers canonical chart checkpoints across new story, save/load and reopen; it passed in the collected 12/12 suite, as recorded in [validation](systemnnn_validation.md). This auditor did not independently rerun that complete chart fixture.

**Regression specification:** progress through a chart node from New Game with a writable directory; save a slot, replace the session using slot load, and verify the node remains jumpable with its exact continuation. Repeat after reopen and without a writable path. Verify only the canonical private chart namespace is written.

## 2. Return-to-title keeps old story voice and sound effects audible

**Severity:** concrete user-visible lifecycle/audio defect; must fix before claiming clean title transitions.

**Source:** original [provider title:156–171](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp) (around 158–173 after concurrent edits) stops movies/minigames but neither stops nor suspends script audio. [audio owner selection and pull:132–149](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L132-L149) continues to choose the retained `game` on the title screen. [GameAudio play_menu_music:944–955](../packages/SystemNNN-Emberfall/core/src/game_audio.cpp#L944-L955) replaces only music; it does not stop voices/SFX.

**Executed isolated reproduction:** a standalone harness included the current provider implementation and the existing independently authored provider fixture generator, linked against existing archives read-only. Its executable and fixtures were written only under `/tmp/systemnnn-source-audit.vzbHrvOK`; compilation and run returned exit code 0. The host audio worker was stopped to eliminate device timing; the test created a valid one-second mono PCM VAW, started voice channel 0, invoked `title()`, then pulled PCM through `audio_game()->audio()`, exactly the owner selected by the callback.

Exact observed output:

```text
voice_active_before=1
voice_active_on_title=1 audible=1 overlay=title
```

This proves audible old voice remains after the title transition, not merely stale bookkeeping.

**Minimal fix:** call `game->audio().stop_script_audio()` when leaving the story for title, before playing the menu BGM. Do not substitute `suspend_script_audio()`: [that API:871–893](../packages/SystemNNN-Emberfall/core/src/game_audio.cpp#L871-L893) deliberately preserves looping tracks, while [stop_script_audio:858–869](../packages/SystemNNN-Emberfall/core/src/game_audio.cpp#L858-L869) clears script voices, effects and backlog voice without destroying BGM. Consider the same cleanup for direct story-to-Extras entry, which also retains the game mixer.

**Post-fix status: independently reproduced PASS.** Recompiled the same isolated harness against the final provider source, retaining existing archives read-only; compile and execution both returned exit code 0. [Final title:163](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L163) and [Extras:238](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L238) now call `stop_script_audio()`. Actual post-title PCM, not only track state, became silent:

```text
voice_active_before=1
voice_active_on_title=0 audible=0 overlay=title
```

The isolated executable was `audit-postfix` in the same private test directory. This verifies the tested voice/title regression; looping SE, direct Extras PCM, and full host/device behavior remain the owning contract tests’ coverage responsibility.

**Regression specification:** start a long voice and looping script SE, return to title midway, assert all script voice/effect tracks stopped and rendered callback PCM contains only the configured title BGM. Test explicit title action, script end returning to title, and direct story-to-Extras transition.

## 3. Back from an Omake child overlay changes only the label to Title

**Severity:** lower-priority concrete menu lifecycle inconsistency, not independently classified as a release blocker.

**Source:** original [provider close_overlay:152–154](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp) (around 154–156 after edits) unconditionally sets `overlay=preview?"title":""`. [extras](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp) creates an Omake preview with its own script and music. Opening settings/load and going Back therefore exposes title controls on an Omake preview, without performing `title()` and its background/music initialization. The existing `previous_overlay` member was unused in the audited source.

Same isolated harness observed:

```text
omake_settings_back_overlay=title
```

Sequence: `extras(); action("settings"); action("back")`.

**Minimal fix:** preserve/restore the preview caller (`title` or `omake`) separately from transient child overlay state; when genuinely navigating to title, call `title()` rather than only changing the overlay string.

**Post-fix status: independently reproduced PASS.** Final [close_overlay:155](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L155) restores `preview_owner`; [Extras:240](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L240) sets it to `omake`. The same source-linked harness, recompiled after the fix, returned exit code 0 and printed:

```text
omake_settings_back_overlay=omake
```

## Coverage and non-findings

- Full movie decoder review covered custom AVIO lifetime, packet EAGAIN/drain handling, timestamp origin, bounded decode pumping, RGB padding, resampler layout/discontinuity/tail handling, and serialized provider movie pulls. No new confirmed FFmpeg crash/blocker was established; do not represent static review as additional sanitizer/runtime coverage.
- Full audio worker review covered OpenAL thread-local context ownership, pause wakeups, start/stop serialization, and callback game-mutex ownership. No new confirmed worker lifetime bug was established. Existing parent fullnative/Java/tiny-movie-ASan passes were not rerun.
- Minigame binding review covered entry gating, parsed CG list tokens, art conversion bounds, completion dispatch and caller-music restoration. No additional independently confirmed minigame release blocker was established.
- A diagnostic showed host action `start` can execute while provider is paused (tick/input are paused, option/menu actions are not). This was deliberately **not** promoted to a release blocker: host lifecycle contract and intended background menu behavior need clarification.
- Windows/macOS cold CI remained outside this audit; no cross-platform build result is claimed.

## Source identity caveat

At the 17:35 follow-up, SHA-256 identities were:

```text
provider 7eaf0987e0470c85f7f700086eec472cf50b30203ff1c012633e8282e457e319
minigame_binding 732e5fe085e2a5974947dc63098896aa8eb404e90fe56671bba34c66587486b5
movie 3e44e244ab4483c17f061592a7e98802ec1c7a9df2d549d76159db06d0b46533
audio f615fb6342be1f8450f50d51b368add18c06d5bf4b1ed1397a33e5de91e92fdb
```

Provider/presenter edits continued during the audit. Original line numbers above identify the detected source, while subsequent fixes can shift lines; search the named methods when validating final status. The title-voice PCM and Omake settings/Back fixes were independently rerun against final provider source and passed as documented above. Chart source changes were inspected but no complete chart scenario was executed by this auditor; additional regression results belong to the owning test agent.
