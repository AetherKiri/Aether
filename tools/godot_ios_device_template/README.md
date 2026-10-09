# Real Ren'Py iPhoneOS debug template

The official Godot 4.7.2 device/debug archive contains strong SDL3 symbols,
including `SDL_Init` and `SDL_GetError`. This application force-loads its existing
SDL2 host libraries. The dedicated Ren'Py device profile therefore builds a
real Godot engine without the SDL3 input driver; native iOS display, touch and
keyboard handling remain enabled and Ren'Py retains its real SDL2 runtime.

`build_godot_ios_device_template.py` uses official commit
`ed1daf0bf001b61586d9930840f2f1394092c079`, the selected cloud Xcode iPhoneOS
SDK and its real Apple compiler. Its explicit options are `platform=ios`,
`target=template_debug`, `arch=arm64`, `ios_simulator=no`, `vulkan=no`,
`metal=no`, `opengl3=yes`, `generate_bundle=no`, and `sdl=no`. No alternate SDK,
Vulkan SDK, new license acceptance, signing identity or device access is used.

The helper checks every real archive object for device platform 2 and arm64,
then replaces only the copied ZIP's two device/debug engine/camera members.
Real native symbol inspection also rejects the host's SDL collision symbols in
the rebuilt archives. The original official template is accepted only as a
source-build input, never as a validated SDL-free device export.
All Simulator, release and metadata members retain their original content
hashes. `evidence.json` records the source pin, actual compiler/SDK, exact
command, archive/template hashes and the actual source-build result. Source
and bundle validation cannot prove installation or phone gameplay.

The opt-in profile binds the copied `iOS Debug` preset to the exact new template,
adds only `renpy_ios_device_gles` and temporarily adds the corresponding
Compatibility rendering override to `project.godot`. It does not use a
Simulator feature or alter the ordinary device renderer. Export inputs must
be restored on success or failure by the application build script.

With a fresh output directory on a cloud Mac using existing licensed Xcode:

```bash
python3 tools/build_godot_ios_device_template.py build \
  --input-template "$GODOT_EXPORT_TEMPLATE" \
  --output-template "$RUNNER_TEMP/godot-renpy-device/ios.zip" \
  --output-dir "$RUNNER_TEMP/godot-renpy-device" --jobs 3
export GODOT_EXPORT_TEMPLATE="$RUNNER_TEMP/godot-renpy-device/ios.zip"
export AETHERKIRI_RENPY_IOS_DEVICE_GLES=ON
export AETHERKIRI_ENABLE_RENPY=ON
bash scripts/build_ios.sh debug --package-ipa
```

The opt-in flag requires a Debug device build with Ren'Py enabled. The script
backs up and restores all three export input files, checks the real exported
device archives against the verified template, then performs actual unsigned
`xcodebuild` packaging. The resulting unsigned IPA still requires authorized
signing before installation; this workflow does not establish phone gameplay.

`test_godot_ios_device_template.py` inspects the real official device archives,
compiles real Apple-target objects to reject the wrong device/Simulator
platform, checks a full actual ZIP roundtrip, and uses genuine Godot 4.7.2 to
export/load an iOS PCK. The PCK check establishes the custom feature and
selected renderer setting; it does not execute an iOS renderer or Ren'Py.
