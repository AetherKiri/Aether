#!/usr/bin/env python3
"""Attach the upstream Android player sources to the generated Godot project."""
from pathlib import Path
import argparse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID = "{http://schemas.android.com/apk/res/android}"


def stage(build, enabled):
    package = ROOT / "packages/AetherSystemNNN/platform/android"
    gradle = build / "build.gradle"
    manifest = build / "src/main/AndroidManifest.xml"
    ET.register_namespace("android", ANDROID[1:-1])
    ET.register_namespace("tools", "http://schemas.android.com/tools")
    tree = ET.parse(manifest)
    app = tree.getroot().find("application")
    name = "com.tyranor.runtime.systemnnn.PlayerActivity"
    for old in app.findall("activity"):
        if old.get(ANDROID + "name") == name:
            app.remove(old)
    marker = "apply from: 'aether_systemnnn.gradle'"
    script = build / "aether_systemnnn.gradle"
    text = gradle.read_text().replace("\n" + marker, "").rstrip() + "\n"
    if enabled:
        snippet = ET.parse(package / "tyn/integration/AndroidManifest.systemnnn.xml")
        app.append(snippet.getroot().find("application/activity"))
        # Point Gradle at the checked-out Java sources. The tyn directory also
        # contains non-Java integration examples, which Gradle ignores.
        roots = [package / "player/java", package / "app/java", package / "tyn",
                 ROOT / "bridge/systemnnn_runtime/android"]
        # Groovy single-quoted strings avoid interpolation of checkout paths.
        def quote(path):
            return "'" + str(path).replace("\\", "\\\\").replace("'", "\\'") + "'"
        script.write_text("android.sourceSets.main.java.srcDirs += [" + ", ".join(map(quote, roots)) + "]\n"
                          + "android.sourceSets.main.assets.srcDir " + quote(package / "app/assets") + "\n"
                          + "android.buildTypes.release.proguardFile " + quote(package / "tyn/integration/consumer-systemnnn.pro") + "\n"
                          + "android.buildTypes.release.proguardFile " + quote(ROOT / "bridge/systemnnn_runtime/android/aether.pro") + "\n")
        text += "\n" + marker + "\n"
    else:
        script.unlink(missing_ok=True)
    gradle.write_text(text)
    tree.write(manifest, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--native-manifest", type=Path, required=True)
    args = parser.parse_args()
    stage(args.build_dir, any(Path(line).name == "libsystemnnn.so"
                              for line in args.native_manifest.read_text().splitlines()))
