#!/usr/bin/env python3
"""Compile the Android host with the SDK and test its real resource handler."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-jar", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    jars = sorted(Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")).glob("platforms/*/android.jar"))
    jar = args.android_jar or (jars[-1] if jars else None)
    if jar is None or not jar.is_file():
        parser.error("Pass --android-jar or set ANDROID_HOME to an installed Android SDK")
    source = repo / "bridge/tyrano_runtime/android/src/main/java/org/aether/tyrano"
    with tempfile.TemporaryDirectory(prefix="aether-tyrano-android-") as temp:
        classes = Path(temp) / "classes"
        classes.mkdir()
        subprocess.run(["javac", "-Xlint:all", "--release", "8", "-classpath", str(jar), "-d", str(classes), *map(str, source.glob("*.java"))], check=True)
        subprocess.run(["javac", "-classpath", str(classes), "-d", str(classes), str(repo / "tests/tyrano_mobile/TyranoFilesTest.java")], check=True)
        subprocess.run(["java", "-classpath", str(classes), "TyranoFilesTest"], check=True)
        spec = importlib.util.spec_from_file_location("stage_tyrano", repo / "tools/stage_tyrano_android.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        template = Path(temp) / "template"
        template.mkdir()
        (template / "build.gradle").write_text("plugins { id 'com.android.application' }\n")
        module.stage(template)
        first = (template / "build.gradle").read_text()
        module.stage(template)
        assert (template / "build.gradle").read_text() == first
        # Match Godot's export cleanup; the native host must survive it.
        for relative in ("src/main/assets", "assetPackInstallTime/src/main/assets"):
            generated = template / relative
            generated.mkdir(parents=True, exist_ok=True)
            (generated / "godot-generated.pck").write_text("generated content")
            shutil.rmtree(generated)
        assert (template / "aether_tyrano_assets/aether_tyrano_host.js").read_bytes() == (repo / "bridge/tyrano_runtime/host.js").read_bytes()
        assert "android.sourceSets.main.assets.srcDir file('aether_tyrano_assets')" in (template / "aether_tyrano.gradle").read_text()
        assert (template / "src/main/java/org/aether/tyrano/TyranoHost.java").is_file()
        assert "-keep class org.aether.tyrano" in (template / "aether_tyrano.pro").read_text()
        print("TYRANO_ANDROID_STAGING_OK")


if __name__ == "__main__":
    main()
