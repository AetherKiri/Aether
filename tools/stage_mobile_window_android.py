#!/usr/bin/env python3
"""Stage the mobile-window bridge in Godot's generated Android template."""
import argparse
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET
from stage_app_icons import stage_android_icons


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
    # The sharing provider exposes only temporary ZIP copies, never game files.
    android = "http://schemas.android.com/apk/res/android"
    ET.register_namespace("android", android)
    ET.register_namespace("tools", "http://schemas.android.com/tools")
    tree = ET.fromstring(manifest)
    application = tree.find("application")
    if application is None:
        raise ValueError("Android template has no application")
    authority = "${applicationId}.aether.saves"
    provider = next((item for item in application.findall("provider") if item.get(f"{{{android}}}authorities") == authority), None)
    if provider is None:
        provider = ET.SubElement(application, "provider", {
            f"{{{android}}}name": "org.aether.mobile.SaveFileProvider",
            f"{{{android}}}authorities": authority,
            f"{{{android}}}exported": "false", f"{{{android}}}grantUriPermissions": "true"})
        ET.SubElement(provider, "meta-data", {
            f"{{{android}}}name": "android.support.FILE_PROVIDER_PATHS",
            f"{{{android}}}resource": "@xml/aether_save_share_paths"})
    # A dedicated subclass prevents Android's manifest merger from combining
    # this restricted provider with Godot's separate file picker provider.
    provider.set(f"{{{android}}}name", "org.aether.mobile.SaveFileProvider")
    stage_android_icons(build, application)
    (build / "src/main/AndroidManifest.xml").write_text(ET.tostring(tree, encoding="unicode") + "\n")
    paths = build / "src/main/res/xml/aether_save_share_paths.xml"
    paths.parent.mkdir(parents=True, exist_ok=True)
    paths.write_text('<paths><cache-path name="saves" path="aether-save-share/" /></paths>\n')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    stage(parser.parse_args().build_dir)
