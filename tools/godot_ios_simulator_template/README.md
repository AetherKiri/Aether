# Real Godot 4.7.2 arm64 Simulator template

The official 4.7.2 `ios.zip` advertises arm64 and x86_64 Simulator support in
its plists, but its debug engine and camera Simulator archives contain only
x86_64 objects. `build_godot_ios_simulator_template.py` builds both missing
arm64 archives from official Godot commit
`ed1daf0bf001b61586d9930840f2f1394092c079` using the selected cloud Xcode
iPhoneSimulator SDK. It uses Compatibility rendering, which the application's
Simulator preset also selects. The engine's SDL3 joystick driver is disabled
(`sdl=no`) because this application force-loads its existing SDL2 host libraries;
Godot's native iOS display, touch and keyboard paths remain in the engine, and
Ren'Py retains its real SDL2 runtime. It does not download an alternate SDK or
accept SDK licenses.

On a cloud Apple Silicon Mac with existing licensed Xcode and Python/SCons:

```bash
python3 tools/build_godot_ios_simulator_template.py build \
  --input-template "$GODOT_EXPORT_TEMPLATE" \
  --output-template "$RUNNER_TEMP/godot-arm64-simulator/ios.zip" \
  --output-dir "$RUNNER_TEMP/godot-arm64-simulator" --jobs 3
export GODOT_EXPORT_TEMPLATE="$RUNNER_TEMP/godot-arm64-simulator/ios.zip"
bash scripts/build_ios.sh debug --simulator --simulator-arch=arm64
```

Use a fresh output directory for each source build. Both original x86_64 debug
Simulator slices are preserved byte for byte with real `lipo`; only the two
debug Simulator archive members change in the copied ZIP. Every other member,
including all device/release slices and metadata, retains its original payload
hash. Every archive object must identify the actual Simulator platform 7, and
the corrected universal archives must agree with the plist architecture lists.
`evidence.json` records the fixed source commit, compiler, SDK, exact build
command, template/archive hashes and actual build status. This is source-build
evidence; it does not prove an application launched or a game was playable.

`scripts/build_ios.sh` temporarily binds the selected export preset's
`custom_template/debug` to this exact template and restores both the preset and
GDExtension configuration on success or failure. It checks every Simulator
archive on entry and verifies the actual exported archives against the same
template hashes. Cached templates therefore undergo the same binary checks.
Continue with the real XCUITest gameplay harness in
[`tools/renpy_ios_acceptance/README.md`](../renpy_ios_acceptance/README.md).

`test_godot_ios_simulator_template.py --template ORIGINAL_IOS_ZIP` inspects the
real official archives and compiles real LLVM/Xcode objects to check CPU and
platform rejection. Darwin also checks genuine `lipo` universal archives. Linux
can run the thin-object checks with `--clang PATH --ar PATH` using existing
LLVM tools; it does not build Godot, use an Apple SDK or execute iOS software.
