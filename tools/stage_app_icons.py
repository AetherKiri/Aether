#!/usr/bin/env python3
"""Bundle interface-specific system icons without rewriting signed app resources."""
import argparse
import copy
import hashlib
from pathlib import Path
import plistlib
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "apps/godot_app/assets"
ANDROID = "http://schemas.android.com/apk/res/android"


def stage_android_icons(build, application):
    attr = lambda key: "{" + ANDROID + "}" + key
    # Preserve Godot's existing launcher component for upgrades and pinned
    # shortcuts. It becomes the default Astryx identity; Classic is alternate.
    primary = next((a for a in application.findall("activity-alias")
                    if a.get(attr("name")) in (".GodotAppLauncher", "com.godot.game.GodotAppLauncher")), None)
    if primary is None:
        raise ValueError("Android template has no GodotAppLauncher alias")
    primary.set(attr("enabled"), "true")
    primary.set(attr("icon"), "@mipmap/icon")
    name = "com.godot.game.AetherClassicLauncher"
    classic = next((a for a in application.findall("activity-alias") if a.get(attr("name")) == name), None)
    if classic is None:
        classic = copy.deepcopy(primary)
        application.insert(list(application).index(primary) + 1, classic)
    classic.set(attr("name"), name)
    classic.set(attr("enabled"), "false")
    classic.set(attr("icon"), "@mipmap/aether_classic")
    # Full-resolution resources keep task icons and high-density launchers crisp.
    files = {
        "mipmap-nodpi/aether_classic.png": ASSETS / "icon.png",
        "drawable-nodpi/aether_classic_task.png": ASSETS / "icon.png",
        "drawable-nodpi/aether_astryx_task.png": ASSETS / "icons/astryx/icon.png",
        "drawable-nodpi/aether_classic_foreground.png": ASSETS / "icons/icon_adaptive_fg.png",
        "drawable-nodpi/aether_classic_background.png": ASSETS / "icons/icon_adaptive_bg.png",
    }
    res = build / "src/main/res"
    for relative, source in files.items():
        destination = res / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    adaptive = res / "mipmap-anydpi-v26/aether_classic.xml"
    adaptive.parent.mkdir(parents=True, exist_ok=True)
    adaptive.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<adaptive-icon xmlns:android="{ANDROID}">\n'
        '  <background android:drawable="@drawable/aether_classic_background" />\n'
        '  <foreground android:drawable="@drawable/aether_classic_foreground" />\n'
        '</adaptive-icon>\n')


def stage_ios_icons(project):
    from stage_ios_game_import import app_target, configurations, read_project, write_project, write_plist
    data = read_project(project)
    objects = data["objects"]
    _, app = app_target(data)
    export = project.parent
    # Use explicit alternate image files, so this also works with Godot exports
    # whose primary icon catalog was generated before Xcode's alternate assets.
    icons = {
        "AetherClassic60@2x.png": 120, "AetherClassic60@3x.png": 180,
        "AetherClassic76@2x.png": 152, "AetherClassic83.5@2x.png": 167,
        "AetherClassic40@2x.png": 80, "AetherClassic40@3x.png": 120,
        "AetherClassic29@2x.png": 58, "AetherClassic29@3x.png": 87,
    }
    for config in configurations(objects, app):
        info_path = export / config["buildSettings"]["INFOPLIST_FILE"].strip('"')
        info = plistlib.loads(info_path.read_bytes())
        for key, files in (
            ("CFBundleIcons", ["AetherClassic60", "AetherClassic40", "AetherClassic29"]),
            ("CFBundleIcons~ipad", ["AetherClassic76", "AetherClassic83.5", "AetherClassic60", "AetherClassic40", "AetherClassic29"]),
        ):
            info.setdefault(key, {}).setdefault("CFBundleAlternateIcons", {})["Classic"] = {
                "CFBundleIconFiles": files, "UIPrerenderedIcon": False}
        write_plist(info_path, info)
    resource_phase = next(objects[p] for p in app["buildPhases"]
                          if objects[p]["isa"] == "PBXResourcesBuildPhase")
    root_group = objects[objects[data["rootObject"]]["mainGroup"]]
    for filename, size in icons.items():
        path = Path("AetherAlternateIcons") / filename
        target = export / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ASSETS / f"icons/icon_{size}x{size}.png", target)
        ref = hashlib.sha256(("AetherAppIcon/ref/" + filename).encode()).hexdigest()[:24].upper()
        build = hashlib.sha256(("AetherAppIcon/build/" + filename).encode()).hexdigest()[:24].upper()
        objects[ref] = {"isa": "PBXFileReference", "lastKnownFileType": "image.png",
                        "path": str(path), "sourceTree": "SOURCE_ROOT"}
        objects[build] = {"isa": "PBXBuildFile", "fileRef": ref}
        if build not in resource_phase["files"]:
            resource_phase["files"].append(build)
        if ref not in root_group["children"]:
            root_group["children"].append(ref)
    write_project(project, data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios-project", type=Path, required=True)
    stage_ios_icons(parser.parse_args().ios_project)
