#!/usr/bin/env python3
"""Install Aether's own Tyrano host into a generated Godot Gradle template."""
import argparse
from pathlib import Path
import shutil


def stage(build: Path):
    repo = Path(__file__).resolve().parents[1]
    source = repo / "bridge/tyrano_runtime/android"
    gradle = build / "build.gradle"
    if not gradle.is_file():
        raise ValueError(f"Not a Godot Android build template: {build}")
    for java in (source / "src/main/java").rglob("*.java"):
        target = build / java.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(java, target)
    # Godot clears src/main/assets (and the AAB asset-pack directory) before
    # each export. Keep our native asset in a separate Gradle source set.
    assets = build / "aether_tyrano_assets"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(repo / "bridge/tyrano_runtime/host.js", assets / "aether_tyrano_host.js")
    legacy = build / "src/main/assets/aether_tyrano_host.js"
    if legacy.is_file():
        legacy.unlink()
    (build / "aether_tyrano.pro").write_text("-keep class org.aether.tyrano.** { *; }\n")
    (build / "aether_tyrano.gradle").write_text(
        "android.sourceSets.main.assets.srcDir file('aether_tyrano_assets')\n"
        "android.buildTypes.configureEach { proguardFile file('aether_tyrano.pro') }\n")
    include = "apply from: 'aether_tyrano.gradle'"
    text = gradle.read_text()
    if include not in text:
        gradle.write_text(text.rstrip() + "\n\n" + include + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    stage(parser.parse_args().build_dir)
