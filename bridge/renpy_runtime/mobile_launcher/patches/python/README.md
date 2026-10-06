# Ren'Py Python cooperative-loop patch

`0001-cooperative-loop-skeleton.patch` is an opt-in source patch against the
official Ren'Py source checkout. It is validated against the current
`renpy/renpy` master tree in Mobile Contract CI.

Apply or validate it with:

```text
bridge/renpy_runtime/mobile_launcher/build.sh \
  --check-python-patch --renpy-src /path/to/renpy

bridge/renpy_runtime/mobile_launcher/build.sh \
  --apply-python-patch --renpy-src /path/to/renpy
```

The patch keeps the normal `main.run()` and `execution.run_context()` behavior
unchanged for desktop. The opt-in path adds:

- `renpy.main.cooperative_start()` to initialize a game context once
- `renpy.main.cooperative_tick(budget_ms)` to resume that same context for a
  bounded host tick and return `yield`, `finished`, or `not_started`
- `renpy.main.cooperative_stop()` for host-owned cleanup without process exit
- `renpy.execution.CooperativeYield` and deadline checks at the context boundary
- an event-loop deadline check in `Interface.interact_core`, so a long-running
  interaction yields back to the native host instead of sleeping indefinitely

The native Android/iOS launcher fork must initialize Python and call these
helpers from the interpreter-owning thread. It must still provide the SDL/GLES
or Metal frame bridge, input queue, pause/resume, and seven exported
`renpy_mobile_*` symbols. The official `SDL_main`/`launcher_main` entrypoints
remain process launchers and are never used by this patch.
