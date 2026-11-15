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
    # shortcuts. It becomes Astryx light; Classic and Astryx dark are alternates.
    primary = next((a for a in application.findall("activity-alias")
                    if a.get(attr("name")) in (".GodotAppLauncher", "com.godot.game.GodotAppLauncher")), None)
    if primary is None:
        raise ValueError("Android template has no GodotAppLauncher alias")
    primary.set(attr("enabled"), "true")
    primary.set(attr("icon"), "@mipmap/icon")
    for name, resource in (("com.godot.game.AetherClassicLauncher", "aether_classic"),
                           ("com.godot.game.AetherAstryxDarkLauncher", "aether_astryx_dark")):
        alternate = next((a for a in application.findall("activity-alias") if a.get(attr("name")) == name), None)
        if alternate is None:
            alternate = copy.deepcopy(primary)
            application.append(alternate)
        alternate.set(attr("name"), name)
        alternate.set(attr("enabled"), "false")
        alternate.set(attr("icon"), "@mipmap/" + resource)
    # Full-resolution resources keep task icons and high-density launchers crisp.
    files = {
        "mipmap-nodpi/aether_classic.png": ASSETS / "icon.png",
        "drawable-nodpi/aether_classic_task.png": ASSETS / "icon.png",
        "drawable-nodpi/aether_astryx_task.png": ASSETS / "icons/astryx/icon.png",
        "drawable-nodpi/aether_classic_foreground.png": ASSETS / "icons/icon_adaptive_fg.png",
        "drawable-nodpi/aether_classic_background.png": ASSETS / "icons/icon_adaptive_bg.png",
        "mipmap-nodpi/aether_astryx_dark.png": ASSETS / "icons/astryx/dark/icon.png",
        "drawable-nodpi/aether_astryx_dark_task.png": ASSETS / "icons/astryx/dark/icon.png",
        "drawable-nodpi/aether_astryx_dark_foreground.png": ASSETS / "icons/astryx/dark/icon_adaptive_fg.png",
        "drawable-nodpi/aether_astryx_dark_background.png": ASSETS / "icons/astryx/dark/icon_adaptive_bg.png",
    }
    res = build / "src/main/res"
    for relative, source in files.items():
        destination = res / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    for resource in ("aether_classic", "aether_astryx_dark"):
        adaptive = res / f"mipmap-anydpi-v26/{resource}.xml"
        adaptive.parent.mkdir(parents=True, exist_ok=True)
        adaptive.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            f'<adaptive-icon xmlns:android="{ANDROID}">\n'
            f'  <background android:drawable="@drawable/{resource}_background" />\n'
            f'  <foreground android:drawable="@drawable/{resource}_foreground" />\n'
            '</adaptive-icon>\n')


def stage_ios_icons(project):
    from stage_ios_game_import import app_target, configurations, read_project, write_project, write_plist
    data = read_project(project)
    objects = data["objects"]
    _, app = app_target(data)
    export = project.parent
    # Use explicit alternate image files, so this also works with Godot exports
    # whose primary icon catalog was generated before Xcode's alternate assets.
    sizes = {"60@2x": 120, "60@3x": 180, "76@2x": 152, "83.5@2x": 167,
             "40@2x": 80, "40@3x": 120, "29@2x": 58, "29@3x": 87}
    variants = {"Classic": ASSETS / "icons", "AstryxDark": ASSETS / "icons/astryx/dark"}
    icons = {f"Aether{variant}{suffix}.png": source / f"icon_{size}x{size}.png"
             for variant, source in variants.items() for suffix, size in sizes.items()}
    for config in configurations(objects, app):
        info_path = export / config["buildSettings"]["INFOPLIST_FILE"].strip('"')
        info = plistlib.loads(info_path.read_bytes())
        for key, suffixes in (
            ("CFBundleIcons", ["60", "40", "29"]),
            ("CFBundleIcons~ipad", ["76", "83.5", "60", "40", "29"]),
        ):
            alternates = info.setdefault(key, {}).setdefault("CFBundleAlternateIcons", {})
            for variant in variants:
                alternates[variant] = {"CFBundleIconFiles": [f"Aether{variant}{s}" for s in suffixes],
                                       "UIPrerenderedIcon": False}
        write_plist(info_path, info)
    resource_phase = next(objects[p] for p in app["buildPhases"]
                          if objects[p]["isa"] == "PBXResourcesBuildPhase")
    root_group = objects[objects[data["rootObject"]]["mainGroup"]]
    for filename, source in icons.items():
        path = Path("AetherAlternateIcons") / filename
        target = export / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
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
