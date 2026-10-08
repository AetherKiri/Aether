# Native lifecycle patch

The source runner applies these patches to the pinned SDL2/Python3
renpy-build revision, then copies `renpy_mobile_lifecycle.c` and the versioned
ABI header into that checkout. It compiles the shared native lifecycle and
linked greenlet for Android and every selected iOS target. The platform
bootstrap initializes CPython without calling the process launchers.

`renpy_mobile_lifecycle.c` owns the copied host callback table and the borrowed
frame byte storage. It invokes the full cooperative Python entrypoints,
preserves pointer/key/text actions, publishes renderer screenshots and
returns observable normal-exit and text-input state. Window binding connects
the real SDL renderer window to the Android EGL context handoff.

These sources need actual target compilation and cloud-device gameplay
acceptance. A successful host compilation or exported-symbol check is not
mobile playability evidence. The iOS MetalANGLE host rendering integration
remains blocked and the provider refuses it explicitly.
