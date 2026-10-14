#!/usr/bin/env python3
"""Stage the native runtime into Godot's generated Android Gradle project."""
import argparse
from pathlib import Path
import re
import shutil


def stage(build, runtime):
    if not (build / "build.gradle").is_file():
        raise ValueError("Not a Godot Gradle template")
    for source, target in (("java", "aether_renpy_java"), ("jni", "aether_renpy_jni"), ("assets", "aether_renpy_assets")):
        shutil.copytree(runtime / source, build / target, dirs_exist_ok=True)
    candidates = list(build.glob("src/**/GodotApp.java"))
    if len(candidates) != 1:
        raise ValueError("Expected the generated GodotApp.java entry point")
    app = candidates[0]
    text = app.read_text()
    text, count = re.subn(r"(class GodotApp extends )(?:GodotActivity|org\.godotengine\.godot\.GodotActivity|org\.renpy\.android\.PythonSDLActivity)\b",
                          r"\1org.renpy.android.PythonSDLActivity", text)
    if count != 1:
        raise ValueError("The Godot Android entry point changed")
    app.write_text(text)
    (build / "aether_renpy.pro").write_text(
        "-keep class org.aether.renpy.** { *; }\n"
        "-keep class org.aether.sdl.** { *; }\n"
        "-keep class org.renpy.android.** { *; }\n")
    (build / "aether_renpy.gradle").write_text(
        "android.sourceSets.main.java.srcDir file('aether_renpy_java')\n"
        "android.sourceSets.main.jniLibs.srcDir file('aether_renpy_jni')\n"
        "android.sourceSets.main.assets.srcDir file('aether_renpy_assets')\n"
        "android.buildTypes.configureEach { proguardFile file('aether_renpy.pro') }\n")
    gradle = build / "build.gradle"
    include = "apply from: 'aether_renpy.gradle'"
    text = gradle.read_text()
    if include not in text: gradle.write_text(text.rstrip() + "\n\n" + include + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    args = parser.parse_args()
    stage(args.build_dir.resolve(), args.runtime.resolve())
