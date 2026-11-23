#!/usr/bin/env python3
"""Bundle interface-specific system icons without rewriting signed app resources."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "apps/godot_app/assets"
COMPOSER = ROOT / "tools/branding/AetherAppIcon.icon"
IOS_ALTERNATES = {"Classic": ASSETS / "icons", "AstryxDark": ASSETS / "icons/astryx/dark"}
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


def stage_composer_icons(export):
    files = {}
    for name in (COMPOSER.stem, *IOS_ALTERNATES):
        path = Path("AetherAppIcons") / f"{name}.icon"
        shutil.copytree(COMPOSER, export / path, dirs_exist_ok=True)
        files[path] = "folder.iconcomposer.icon"
        if name == "AstryxDark":
            # Keep the saved Astryx dark selection as the default appearance
            # of this alternate. Icon Composer still handles system effects.
            manifest = export / path / "icon.json"
            icon = json.loads(manifest.read_text())
            layers = [layer for group in icon["groups"] for layer in group["layers"]]
            for entry in (icon, *layers):
                fills = entry["fill-specializations"]
                dark = next(fill["value"] for fill in fills if fill.get("appearance") == "dark")
                entry["fill-specializations"] = [
                    {"value": dark}, *(fill for fill in fills if "appearance" in fill)
                ]
            manifest.write_text(json.dumps(icon, indent=2) + "\n")
    return files


def stage_legacy_ios_icons(export):
    # Keep the legacy loose images for Xcode versions without Icon Composer.
    sizes = {"60@2x": 120, "60@3x": 180, "76@2x": 152, "83.5@2x": 167,
             "40@2x": 80, "40@3x": 120, "29@2x": 58, "29@3x": 87}
    files = {}
    for name, source in IOS_ALTERNATES.items():
        for suffix, size in sizes.items():
            path = Path("AetherAlternateIcons") / f"Aether{name}{suffix}.png"
            target = export / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / f"icon_{size}x{size}.png", target)
            files[path] = "image.png"
    return files


def stage_ios_icons(project, *, liquid_glass):
    from stage_ios_game_import import app_target, configurations, read_project, write_project, write_plist

    data = read_project(project)
    objects = data["objects"]
    _, app = app_target(data)
    export = project.parent
    files = stage_composer_icons(export) if liquid_glass else stage_legacy_ios_icons(export)

    for config in configurations(objects, app):
        settings = config["buildSettings"]
        if liquid_glass:
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = COMPOSER.stem
            settings["ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES"] = " ".join(IOS_ALTERNATES)
        info_path = export / settings["INFOPLIST_FILE"].strip('"')
        info = plistlib.loads(info_path.read_bytes())
        for key, suffixes in (
            ("CFBundleIcons", ["60", "40", "29"]),
            ("CFBundleIcons~ipad", ["76", "83.5", "60", "40", "29"]),
        ):
            if liquid_glass:
                # actool emits the declarations and backward-compatible images
                # for both device families from the three .icon packages.
                family = info.get(key, {})
                family.pop("CFBundlePrimaryIcon", None)
                alternates = family.get("CFBundleAlternateIcons", {})
                for name in IOS_ALTERNATES:
                    alternates.pop(name, None)
                if not alternates:
                    family.pop("CFBundleAlternateIcons", None)
                if not family:
                    info.pop(key, None)
            else:
                alternates = info.setdefault(key, {}).setdefault("CFBundleAlternateIcons", {})
                for name in IOS_ALTERNATES:
                    alternates[name] = {"CFBundleIconFiles": [f"Aether{name}{s}" for s in suffixes],
                                        "UIPrerenderedIcon": False}
        write_plist(info_path, info)

    resource_phase = next(objects[p] for p in app["buildPhases"]
                          if objects[p]["isa"] == "PBXResourcesBuildPhase")
    root_group = objects[objects[data["rootObject"]]["mainGroup"]]
    for path, file_type in files.items():
        ref = hashlib.sha256(("AetherAppIcon/ref/" + path.name).encode()).hexdigest()[:24].upper()
        build = hashlib.sha256(("AetherAppIcon/build/" + path.name).encode()).hexdigest()[:24].upper()
        objects[ref] = {"isa": "PBXFileReference", "lastKnownFileType": file_type,
                        "path": path.as_posix(), "sourceTree": "SOURCE_ROOT"}
        objects[build] = {"isa": "PBXBuildFile", "fileRef": ref}
        if build not in resource_phase["files"]:
            resource_phase["files"].append(build)
        if ref not in root_group["children"]:
            root_group["children"].append(ref)
    write_project(project, data)


def supports_icon_composer():
    version = plistlib.loads(subprocess.check_output(["xcrun", "actool", "--version"]))
    short_version = version["com.apple.actool.version"]["short-bundle-version"]
    return int(short_version.split(".", 1)[0]) >= 26


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios-project", type=Path, required=True)
    stage_ios_icons(parser.parse_args().ios_project, liquid_glass=supports_icon_composer())
