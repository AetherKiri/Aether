#!/usr/bin/env python3
"""Stage the mobile-window bridge in Godot's generated Android template."""
import argparse
from pathlib import Path
import shutil


def stage(build: Path):
    source = Path(__file__).resolve().parents[1] / "bridge/mobile_window/android"
    gradle = build / "build.gradle"
    if not gradle.is_file():
        raise ValueError(f"Not a Godot Android build template: {build}")
    for java in (source / "src/main/java").rglob("*.java"):
        target = build / java.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(java, target)
    # JavaClassWrapper calls these methods by name, including in release builds.
    (build / "aether_mobile_window.pro").write_text("-keep class org.aether.mobile.** { *; }\n")
    (build / "aether_mobile_window.gradle").write_text(
        "android.buildTypes.configureEach { proguardFile file('aether_mobile_window.pro') }\n")
    include = "apply from: 'aether_mobile_window.gradle'"
    text = gradle.read_text()
    if include not in text:
        gradle.write_text(text.rstrip() + "\n\n" + include + "\n")
    # These capabilities are part of Godot 4.7's template. Fail clearly on an
    # older template instead of shipping a setting that silently does nothing.
    activity = (build / "src/main/java/com/godot/game/GodotApp.java").read_text()
    manifest = (build / "src/main/AndroidManifest.xml").read_text()
    if "isPiPEnabled" not in activity or 'android:supportsPictureInPicture="true"' not in manifest:
        raise ValueError("Picture in Picture requires the Godot 4.7 Android template")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    stage(parser.parse_args().build_dir)
