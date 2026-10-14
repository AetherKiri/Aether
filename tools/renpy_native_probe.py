#!/usr/bin/env python3
"""Build a small Godot app exercising the production native Ren'Py player.

It has no private engine dependencies. Linux runs with the real X11/GL host;
Android uses the same staged SDL Activity, JNI bridge and asset installer as
the product. The original Chinese fixture is copied to writable app storage.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("linux", "android"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True, help="Source SDK containing the test font")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--godot-cpp", type=Path)
    parser.add_argument("--ndk", type=Path)
    parser.add_argument("--abi", choices=("arm64-v8a", "x86_64"), default="x86_64")
    parser.add_argument("--android-renderer", choices=("mobile", "gl_compatibility"), default="mobile")
    parser.add_argument("--host-only", action="store_true", help="Diagnose the Godot renderer without loading the Ren'Py SDK")
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    project = output / "project"; project.mkdir(exist_ok=True)
    native = output / "native"
    command = ["cmake", "-S", REPO / "tests/renpy_mobile", "-B", native, "-DCMAKE_BUILD_TYPE=Release"]
    if args.godot_cpp: command += ["-DFETCHCONTENT_SOURCE_DIR_GODOT_CPP=" + str(args.godot_cpp.resolve())]
    if args.platform == "android":
        if not args.ndk: parser.error("Android needs --ndk")
        command += ["-DCMAKE_TOOLCHAIN_FILE=" + str(args.ndk.resolve() / "build/cmake/android.toolchain.cmake"),
                    "-DANDROID_ABI=" + args.abi, "-DANDROID_PLATFORM=android-26", "-DANDROID_STL=c++_static"]
    run(command)
    run(["cmake", "--build", native, "-j", min(os.cpu_count() or 2, 6)])
    binary = project / "bin"; binary.mkdir(exist_ok=True)
    shutil.copy2(native / "librenpy_probe.so", binary)
    if args.platform == "linux": shutil.copy2(native / "libaether_renpy_sdl_hook.so", binary)
    libraries = '''linux.debug.x86_64="res://bin/librenpy_probe.so"
linux.release.x86_64="res://bin/librenpy_probe.so"
linux.debug.arm64="res://bin/librenpy_probe.so"
linux.release.arm64="res://bin/librenpy_probe.so"
''' if args.platform == "linux" else '''android.debug.x86_64="res://bin/librenpy_probe.so"
android.debug.arm64="res://bin/librenpy_probe.so"
android.release.x86_64="res://bin/librenpy_probe.so"
android.release.arm64="res://bin/librenpy_probe.so"
'''
    (project / "probe.gdextension").write_text('''[configuration]
entry_symbol="renpy_probe_init"
compatibility_minimum="4.6"
[libraries]
''' + libraries)
    scripts = project / "scripts"; scripts.mkdir(exist_ok=True)
    for name in ("game_metadata.gd", "tyrano_player_view.gd", "renpy_player_view.gd"):
        shutil.copy2(REPO / "apps/godot_app/scripts" / name, scripts)
    shutil.copytree(REPO / "apps/godot_app/renpy_runtime", project / "renpy_runtime", dirs_exist_ok=True)
    shutil.copytree(REPO / "tests/fixtures/renpy_host", project / "fixture", dirs_exist_ok=True)
    shutil.copy2(args.sdk / "sdk-fonts/SourceHanSansLite.ttf", project / "fixture/game/probe.ttf")
    (project / "fixture/game/probe.ttf.import").write_text('[remap]\nimporter="keep"\n')
    shutil.copy2(REPO / "tests/renpy_mobile/godot_smoke.gd", project / "smoke.gd")
    if args.host_only:
        (project / "smoke.gd").write_text('''extends Control
var frames := 0
func _ready() -> void:
    var background := ColorRect.new()
    background.color = Color.DARK_BLUE
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(background)
func _process(_delta: float) -> void:
    frames += 1
    if frames == 60:
        print("RENPY_VULKAN_HOST_OK")
        get_tree().quit()
''')
    (project / "main.tscn").write_text('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://smoke.gd" id="1"]
[node name="NativeRenpySmoke" type="Control"]
layout_mode=3
anchors_preset=15
anchor_right=1.0
anchor_bottom=1.0
grow_horizontal=2
grow_vertical=2
script=ExtResource("1")
''')
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Aether Renpy Native Probe"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7")
[display]
window/size/viewport_width=1280
window/size/viewport_height=720
window/handheld/orientation=0
window/per_pixel_transparency/allowed=true
window/frame_pacing/android/enable_frame_pacing=false
display_server/driver.linuxbsd="x11"
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="ANDROID_RENDERER"
textures/default_filters/use_nearest_mipmap_filter=false
'''.replace("ANDROID_RENDERER", args.android_renderer))
    cache = project / ".godot"; cache.mkdir(exist_ok=True)
    (cache / "extension_list.cfg").write_text("res://probe.gdextension\n")
    run([args.godot, "--headless", "--path", project, "--editor", "--import", "--quit"])
    if args.platform == "linux":
        env = dict(os.environ, AETHER_RENPY_SDK=str(args.runtime.resolve()))
        run([args.godot, "--path", project], env=env, timeout=240)
        return
    gradle = output / "android"; gradle.mkdir(exist_ok=True)
    (gradle / "settings.gradle").write_text('''pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name='RenpyNativeProbe'
''')
    (gradle / "gradle.properties").write_text("android.useAndroidX=true\norg.gradle.jvmargs=-Xmx3g\n")
    (gradle / "build.gradle").write_text('''plugins { id 'com.android.application' version '8.9.2' }
android {
    namespace 'com.godot.game'
    compileSdk 35
    defaultConfig {
        applicationId 'org.aether.tests.renpy'
        minSdk 26
        targetSdk 35
        versionCode 1
        versionName '1.0'
        ndk { abiFilters 'ABI_PLACEHOLDER' }
    }
    compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
}
dependencies {
    implementation 'org.godotengine:godot:4.7.2.stable'
    implementation 'androidx.fragment:fragment:1.8.6'
    implementation 'androidx.core:core-splashscreen:1.0.1'
}
'''.replace("ABI_PLACEHOLDER", args.abi))
    java = gradle / "src/main/java/com/godot/game"; java.mkdir(parents=True, exist_ok=True)
    (java / "GodotApp.java").write_text('''package com.godot.game;
import org.godotengine.godot.GodotActivity;
import java.util.List;
import java.util.ArrayList;
public class GodotApp extends GodotActivity {
    @Override public List<String> getCommandLine() {
        List<String> args = new ArrayList<>(super.getCommandLine());
        args.add("--main-pack"); args.add("res://game.pck");
        return args;
    }
}
''')
    (gradle / "src/main/AndroidManifest.xml").write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
<uses-permission android:name="android.permission.INTERNET" />
<application android:label="Renpy Native Probe" android:theme="@android:style/Theme.Material.Light.NoActionBar" android:hasCode="true">
<meta-data android:name="org.godotengine.rendering.method" android:value="ANDROID_RENDERER" />
<meta-data android:name="org.godotengine.rendering.driver" android:value="ANDROID_DRIVER" />
<activity android:name="com.godot.game.GodotApp" android:exported="true" android:screenOrientation="landscape"
android:configChanges="orientation|keyboardHidden|screenSize|smallestScreenSize|density|keyboard|navigation|uiMode|screenLayout">
<intent-filter><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.LAUNCHER" /></intent-filter>
</activity></application></manifest>'''.replace("ANDROID_RENDERER", args.android_renderer).replace("ANDROID_DRIVER", "vulkan" if args.android_renderer == "mobile" else "opengl3"))
    if not args.host_only:
        run([sys.executable, REPO / "tools/stage_renpy_android.py", "--build-dir", gradle, "--runtime", args.runtime])
    # Loose imported resources are packaged into an ordinary PCK by Godot.
    (project / "export_presets.cfg").write_text('''[preset.0]
name="Probe"
platform="Android"
export_filter="all_resources"
include_filter="*.py,*.rpy,*.ttf"
export_path=""
[preset.0.options]
architectures/arm64-v8a=true
architectures/x86_64=true
''')
    assets = gradle / "src/main/assets"; assets.mkdir(parents=True, exist_ok=True)
    run([args.godot, "--headless", "--path", project, "--export-pack", "Probe", assets / "game.pck"])
    jni = gradle / "src/main/jniLibs" / args.abi; jni.mkdir(parents=True, exist_ok=True)
    shutil.copy2(native / "librenpy_probe.so", jni)
    print("Android Gradle project: " + str(gradle))


if __name__ == "__main__":
    main()
