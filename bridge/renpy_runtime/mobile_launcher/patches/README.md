# Pinned embedded runtime patches

These patches rebuild Ren'Py 8.5.3 from the exact source revisions recorded in
`tools/run_renpy_mobile_source_build.sh`. They are a separate SDL 2.0.20 source
build; they cannot be mixed with the official downloadable SDL3 binary closure.

The native patches compile the lifecycle implementation and target-built
`_aether_greenlet`, add Python initialization without `Py_RunMain`, and enable
Android's private EGL pbuffer. The Python patch runs the complete Ren'Py
bootstrap on a suspended greenlet. Tick sets its deadline before switching into
the game, preserves the interaction stack, and publishes the renderer's RGBA
screenshot. Window creation, recreation and destruction update the native GL
binding. The eleven exports in `../include/renpy_mobile_launcher.h` are checked
before installing the rebuilt payload.

The source runner applies both native and Python patches to the sources that
it actually builds. `--mode prepare` fetches and patches; `--mode check` checks
the build prerequisites; `--mode build` performs the compilation and creates a
provenance manifest only after successful native/resource validation.

Android still requires complete runtime linking, APK packaging and device
acceptance. iOS has a remaining implementation blocker: the stock SDL
UIKit/MetalANGLE path creates its own window. The provider rejects that path
until rendering is integrated with the existing host. Passing patch, symbol or
protocol tests is not evidence of mobile gameplay.

The C files under `android/` and `ios/` ending in `.template` are deliberately
nonfunctional contract fixtures. They are never installed as runtime archives.
See [native/README.md](native/README.md) and [python/README.md](python/README.md)
for the actual build seams and limitations.
