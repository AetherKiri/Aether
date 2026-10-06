# AetherKiri Ren'Py fixture

This is a real, minimal Ren'Py project used to validate the AetherKiri
Ren'Py runtime path. It exercises:

- startup and scene rendering with a bundled SVG image
- text rendering and menu navigation
- pointer/touch activation of screen buttons
- `renpy.input` text entry
- a blocking `renpy.pause` that the host must pause/resume around
- returning from the script and an explicit quit action

Run it with an official Ren'Py SDK:

```bash
RENPY_SDK=/path/to/renpy-sdk bash ../../tools/run_renpy_smoke.sh
```

The automated smoke command compiles the project and initializes Ren'Py. A
device or simulator run is still required to verify the host lifecycle and
input behavior on mobile.
