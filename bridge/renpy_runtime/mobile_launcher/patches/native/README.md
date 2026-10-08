# Native lifecycle patch

The source runner applies these patches to the pinned SDL2/Python3
renpy-build revision, then copies `renpy_mobile_lifecycle.c` and the versioned
ABI header into that checkout. It compiles the shared native lifecycle and
linked greenlet for Android and every selected iOS target. The platform
bootstrap initializes CPython without calling the process launchers.

`0005-optional-cubism.patch` keeps the base runtime build independent of the
optional licensed SDKs. It enables Live2D generation and its native module only
when the target Cubism header exists, and packages `steamapi` only when the
Steam task actually generated that module. Games that require Live2D still
need the Cubism SDK and its runtime library; supplying the header preserves the
upstream compilation path. No native build tasks are marked complete by this
patch.

`renpy_mobile_lifecycle.c` owns the copied host callback table and the borrowed
frame byte storage. It invokes the full cooperative Python entrypoints,
preserves pointer/key/text actions, publishes renderer screenshots and
returns observable normal-exit and text-input state. Window binding connects
the real SDL renderer window to the Android EGL context handoff.

These sources need actual target compilation and cloud-device gameplay
acceptance. A successful host compilation or exported-symbol check is not
mobile playability evidence. The iOS MetalANGLE host rendering integration
remains blocked and the provider refuses it explicitly.
