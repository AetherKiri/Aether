# Ren'Py cooperative execution patch

`0001-cooperative-loop-skeleton.patch` retains its historical filename but now
contains the embedded runtime implementation. It applies to pinned Ren'Py
commit `39895c1e017f0b36ffea2447d97eccd69d76ee1c`, not moving master.

Validate or apply with:

```sh
bridge/renpy_runtime/mobile_launcher/build.sh \
  --check-python-patch --renpy-src /path/to/renpy
bridge/renpy_runtime/mobile_launcher/build.sh \
  --apply-python-patch --renpy-src /path/to/renpy
```

`renpy.aether_mobile` creates a greenlet without running the game during init.
The first tick sets a deadline and enters the complete `renpy.py` bootstrap.
Subsequent ticks resume the same Python and Cython stack. Safe script and
interaction boundaries switch back to the host instead of unwinding an
exception through `interact` cleanup. Arbitrary Python code cannot be forcibly
preempted; a game that blocks between these boundaries can still stall a tick.

Patched pygame modules publish GL-renderer screenshots, bind each actual GL
window immediately, query host pointer/button/key state, and report text-input
visibility. Events retain their down/up/motion semantics, Unicode ownership
and modifier state. Pause suspends ticks; stop requests normal Ren'Py shutdown.
A second session in the same process is rejected because Ren'Py global and
Cython state reuse has not been implemented; restart the host application.

The native fork supplies the target-built `_aether_greenlet` and `_aether_host`
modules. A host wheel or desktop SDK is not a mobile substitute. Cooperative
and native protocol tests exercise controlled boundaries; actual APK/IPA
installation and gameplay acceptance remain separate requirements.
