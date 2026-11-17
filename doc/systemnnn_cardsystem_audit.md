# CardSystem mode 45: source audit

## Finding

**Real mode-45 frontend support is not implementable as a frontend-only change against the current Emberfall GameSession API.** The enum is present, but the entry path creates no CardSystem modal and the core exposes no CardSystem gameplay or completion contract. Do not substitute a generic Back action, minigame completion, or invented success result.

This was a source-only audit; no tests or builds were run. The only audit deliverable is this document.

## Exact source evidence

Paths below are relative to this document.

- [Runtime mode declaration](../packages/SystemNNN-Emberfall/core/include/nnn/runtime_context.hpp#L19-L30): mode 45 is CardSystem; the comment explicitly distinguishes shared numeric mode identities from original rendering/input owners.
- [Command eligibility](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L1043-L1045) and [registration](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L1098-L1100): cardsystem is registered only when configured as a default, created optional class. [Dispatch](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L3814-L3822) calls begin_modal without converting its false result into a pending frontend request.
- [Actual CardSystem entry](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L1943-L1951): the branch only warns, **“CARDSYSTEM upstream class has no completion or cancel action”**. It never calls enter_modal and returns false. Consequently, normal execution emits no CardSystem request, rows or modal wait. [External open_modal](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L5772-L5792) likewise returns false when begin_modal fails.
- [Public modal representation](../packages/SystemNNN-Emberfall/platform/scene/include/emberfall/game_session.hpp#L71-L87) and [public commands](../packages/SystemNNN-Emberfall/platform/scene/include/emberfall/game_session.hpp#L150-L177) are generic containers/interfaces, not evidence of CardSystem semantics.
- [complete_modal](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L2178-L2191) accepts only NameInput and KanjiInput. [act_modal](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L3179-L3260) has no CardSystem case and defaults to rejection.
- [abort_modal](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L2235-L2248) requires an existing matching modal and provides failure recovery, not gameplay success. [resume_native_panel](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L4399-L4409) requires a paused native panel of mode **51**, not 45.
- [Scene regression fixture](../packages/SystemNNN-Emberfall/platform/scene/tests/scene_tests.cpp#L847-L856) requests printcalendar/cardsystem; its [later assertion](../packages/SystemNNN-Emberfall/platform/scene/tests/scene_tests.cpp#L894-L895) expects dialogue and explicitly says unavailable classes do not stall. This is source evidence of the expected fallback, not a test executed during this audit.

## Android upstream is also unavailable

In the checked-out Emberfall Android implementation, [GameRunner modal constants](../packages/SystemNNN-Emberfall/platform/android/player/java/GameRunner.java#L75-L79) skip 45. Its [asset dispatch](../packages/SystemNNN-Emberfall/platform/android/player/java/GameRunner.java#L2213-L2262) has no CardSystem case and assigns an unknown-mode problem by default. [PlayerActivity](../packages/SystemNNN-Emberfall/platform/android/player/java/PlayerActivity.java#L1593-L1596) aborts problematic modals before constructing their frontend.

Together with the explicit core warning, this establishes deliberate non-support in **this Emberfall revision**; there is no functioning Android CardSystem frontend to port. Local tinyan original-reference CardSystem sources were not located in bounded searches. The packaged warning is not independent proof of the original tinyan implementation or its author's intent.

## Do not conflate card minigames or synthetic rows

[MiniGameBoard](../packages/SystemNNN-Emberfall/platform/android/player/java/MiniGameBoard.java#L10-L12) explicitly implements CAllMiniGame types: Monte=6, Pyramid=7 and Golf=8. [complete_minigame](../packages/SystemNNN-Emberfall/platform/scene/src/game_session.cpp#L1374-L1379) validates configured minigame indices/types 1–10; it is not a mode-45 completion API.

The [portable presenter fixture](../tests/systemnnn_presenter_test.cpp#L85-L95) manually assigns CardSystem with rows inherited from Shop and checks a UI hit target, not a core-accepted action or reachable gameplay session. The [presenter notice](../bridge/systemnnn_runtime/src/systemnnn_presenter.cpp#L906-L909) does not add the missing core contract.

## Missing contracts and minimum honest implementation sequence

Authoritative behavior is required for:

1. Entry-argument meanings, configuration, assets and gameplay-state schema.
2. Legal actions, validation and state transitions.
3. Success/failure/cancel outputs, variable writes and rewards.
4. Script suspension, return destinations and resume behavior.
5. Persistence/replay and any RNG/timing requirements.

Obtain a concrete supported implementation/specification first. Implement and verify its core entry/state/action/commit/cancel handlers and persistence; expose stable request/state/action APIs; then implement portable/Android presentation and input. Acceptance must exercise real entry → legal moves → commit or cancel → expected writes/rewards → correct resume, plus stale requests and restore. Until then, retain an explicit unsupported status rather than claim full mode-45 support.
