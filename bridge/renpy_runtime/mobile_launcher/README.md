# Host-owned Ren'Py mobile launcher scaffold

This directory is the reviewable boundary for the native fork required to make
Ren'Py run inside an existing AetherKiri/Godot loop. It is intentionally a
contract and build/replacement scaffold. It does not contain a playable
launcher and it does not alter the current `NOT_SUPPORTED` mobile provider.

## Verified official inputs

The pinned 8.5.3 mobile archives in `renpy-mobile-staged/` contain stripped
outputs only. The corresponding official source/build layout is available in
the `renpy-build` repository:

- `runtime/librenpython_android.c`: `SDL_main` initializes the Android
  environment, calls `call_prepare_python`, and enters `start_python`; the
  latter ends at blocking `Py_RunMain`
- `runtime/librenpython.c`: `launcher_main` builds `PyConfig` and ends at
  blocking `Py_RunMain`
- `runtime/jniwrapperstuff.h`: Android JNI export-name helper
- `tasks/renpython.py`: `build_android` compiles
  `librenpython_android.c`; `link_android` links `librenpython.so`;
  `link_ios` archives `librenpython.o` as `librenpython.a`
- `renios/prototype/main.c`: the UIKit prototype calls
  `SDL_RunApp(..., launcher_main, NULL)` (older SDL2/Renios archives use the
  equivalent `SDL_UIKitRunApp` spelling)

The official command-line hooks are documented by `build.sh --print-plan`:

- Android: `./build.sh --platform android rebuild renpython rapt rapt-sdl2`
- iOS: `./build.sh --platform ios rebuild renpython renios`

The current official outputs are process launchers. Do not call them from a
Godot frame callback and do not copy `renios/prototype/main.c` into the host
application.

## Lifecycle ABI to implement

`include/renpy_mobile_launcher.h` defines ABI version 1 and the required
exports:

- `renpy_mobile_init(config, host)`
- `renpy_mobile_tick(budget_ms)`
- `renpy_mobile_frame(out_frame)`
- `renpy_mobile_input(event)`
- `renpy_mobile_pause()` / `renpy_mobile_resume()`
- `renpy_mobile_shutdown()`

The eventual fork must move Python/SDL setup out of `SDL_main`/`launcher_main`
and make every lifecycle call return promptly. The calls must not invoke
`Py_RunMain`, `SDL_main`, `SDL_RunApp`, `SDL_UIKitRunApp`, `UIApplicationMain`,
or create an Android Activity. `frame` returns a borrowed RGBA view for the
host to copy; the host callback and ownership rules are in the header.

The header is only an ABI contract. There is no stub implementation that could
be mistaken for a functioning engine.

## Rebuild and replacement hook

`build.sh` performs a source-only check by default when invoked as:

```text
bridge/renpy_runtime/mobile_launcher/build.sh \
  --check --renpy-build /path/to/renpy-build
```

Use `--print-plan` to print the official source inputs, task hooks, and exact
staged destinations. A future lifecycle fork is built outside this scaffold,
then installed with explicit ABI-matched artifacts:

```text
bridge/renpy_runtime/mobile_launcher/build.sh --install \
  --renpy-build /path/to/renpy-build \
  --stage /workspace/shared/renpy-mobile-staged \
  --android-so-arm64 /path/to/arm64-v8a/librenpython.so \
  --android-so-armv7 /path/to/armeabi-v7a/librenpython.so \
  --android-so-x86_64 /path/to/x86_64/librenpython.so \
  --ios-debug-a /path/to/debug/librenpython.a \
  --ios-release-a /path/to/release/librenpython.a
```

`--install` refuses artifacts that do not expose all seven lifecycle symbols.
It copies only the explicitly supplied files to:

- RAPT: `rapt/prototype/renpyandroid/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/librenpython.so`
- Renios: `renios/prototype/prebuilt/{debug,release}/librenpython.a`

The script does not build, sign, package, or claim device/simulator support.
After a real fork is installed, the Android/iOS archive probes and host-owned
lifecycle/input/frame tests must be extended before enabling the provider.
