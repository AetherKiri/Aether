# Upstream patch slot

Keep the future lifecycle fork as a small, reviewable patch against the exact
`renpy-build` commit used for a release. The patch should replace or factor
`runtime/librenpython_android.c` and `runtime/librenpython.c` while preserving
Ren'Py's Python/SDL initialization and JNI callbacks.

Required review checks for that patch:

1. `SDL_main`, `launcher_main`, `SDL_RunApp`, and `Py_RunMain` are not used as
   host lifecycle entrypoints
2. the seven `renpy_mobile_*` exports in the sibling ABI header are present on
   every Android and iOS architecture
3. init/tick/frame/input/pause/resume/shutdown are re-entrant only as stated by
   the ABI and return promptly
4. no second Android Activity, UIKit application, SDL application loop, or
   process exit is introduced
5. Android links with the `tasks/renpython.py` `link_android` closure and iOS
   archives with its `link_ios` closure
6. the resulting archives pass symbol checks, host unit tests, and device or
   simulator smoke tests before replacing staged artifacts

No patch is checked in yet: adding a guessed implementation here would make a
non-playable stub look like a runtime. `build.sh --install` is the deliberate
handoff point for the first audited fork.
