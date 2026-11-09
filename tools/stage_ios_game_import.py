#!/usr/bin/env python3
"""Add folder Open In support and the game-import Action extension to an iOS export."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

from stage_renpy_ios import openstep


SOURCE = Path(__file__).resolve().parents[1] / "bridge/ios_game_import"
GROUP_KEY = "com.apple.security.application-groups"


def identifier(name):
    return hashlib.sha256(("AetherGameImport/" + name).encode()).hexdigest()[:24].upper()


def read_project(project):
    return json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")]))


def write_project(project, data):
    file = project / "project.pbxproj"
    file.write_text("// !$*UTF8*$!\n" + openstep(json.loads(json.dumps(data, sort_keys=True))) + "\n")
    subprocess.run(["plutil", "-lint", str(file)], check=True)


def app_target(data):
    objects = data["objects"]
    targets = [(key, objects[key]) for key in objects[data["rootObject"]]["targets"]
               if objects[key].get("productType") == "com.apple.product-type.application"]
    if len(targets) != 1:
        raise ValueError("Expected one iOS application target")
    return targets[0]


def configurations(objects, target):
    return [objects[key] for key in objects[target["buildConfigurationList"]]["buildConfigurations"]]


def write_plist(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(data, sort_keys=False))


def stage(project):
    data = read_project(project)
    objects = data["objects"]
    root = objects[data["rootObject"]]
    app_id, app = app_target(data)
    configs = configurations(objects, app)
    bundles = {c["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] for c in configs}
    if len(bundles) != 1:
        raise ValueError("Game import requires the same app bundle ID in all configurations")
    bundle = bundles.pop()
    if "$" in bundle:
        raise ValueError("Resolve the app bundle ID before staging game import")
    group = "group." + bundle + ".game-import"
    export = project.parent
    extension_dir = export / "AetherGameImport"
    extension_dir.mkdir(exist_ok=True)
    for name in ("GameImportStore.swift", "GameImportActionViewController.swift"):
        shutil.copy2(SOURCE / name, extension_dir / name)
    for locale in SOURCE.glob("*.lproj"):
        shutil.copytree(locale, extension_dir / locale.name, dirs_exist_ok=True)

    for config in configs:
        settings = config["buildSettings"]
        info_path = export / settings["INFOPLIST_FILE"].strip('"')
        info = plistlib.loads(info_path.read_bytes())
        info["AetherImportAppGroup"] = group
        info["LSSupportsOpeningDocumentsInPlace"] = True
        info["UIFileSharingEnabled"] = True
        # Preserve other document handlers supplied by the exporter.
        types = [t for t in info.get("CFBundleDocumentTypes", [])
                 if t.get("CFBundleTypeName") != "Aether Game"]
        types.append({"CFBundleTypeName": "Aether Game", "CFBundleTypeRole": "Editor",
                      "LSHandlerRank": "Alternate",
                      "LSItemContentTypes": ["public.folder", "public.directory", "org.aether.xp3"]})
        info["CFBundleDocumentTypes"] = types
        imported = [t for t in info.get("UTImportedTypeDeclarations", [])
                    if t.get("UTTypeIdentifier") != "org.aether.xp3"]
        imported.append({"UTTypeIdentifier": "org.aether.xp3", "UTTypeDescription": "KiriKiri XP3 Archive",
                         "UTTypeConformsTo": ["public.data"],
                         "UTTypeTagSpecification": {"public.filename-extension": ["xp3"]}})
        info["UTImportedTypeDeclarations"] = imported
        write_plist(info_path, info)
        entitlement = settings.get("CODE_SIGN_ENTITLEMENTS") or "AetherGameImport/Host.entitlements"
        settings["CODE_SIGN_ENTITLEMENTS"] = entitlement
        path = export / entitlement.strip('"')
        entitlements = plistlib.loads(path.read_bytes()) if path.exists() else {}
        groups = entitlements.setdefault(GROUP_KEY, [])
        if group not in groups:
            groups.append(group)
        write_plist(path, entitlements)

    write_plist(extension_dir / "GameImport.entitlements", {GROUP_KEY: [group]})
    matching = ('ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.directory" OR '
                'ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.file-url" OR '
                'ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "org.aether.xp3"')
    predicate = ('extensionItems.@count > 0 AND SUBQUERY(extensionItems, $item, '
                 '$item.attachments.@count > 0 AND $item.attachments.@count <= 20 AND '
                 f'SUBQUERY($item.attachments, $attachment, {matching}).@count == '
                 '$item.attachments.@count).@count == extensionItems.@count')
    write_plist(extension_dir / "Info.plist", {
        "CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "Send to Aether Visual Novels",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "XPC!", "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)", "AetherImportAppGroup": group,
        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleSymbolName": "folder.badge.plus"}},
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.ui-services",
                        "NSExtensionPrincipalClass": "GameImportActionViewController",
                        "NSExtensionAttributes": {"NSExtensionActivationRule": predicate}},
    })

    def put(name, value):
        key = identifier(name)
        objects[key] = value
        return key

    def append(array, value):
        if value not in array:
            array.append(value)

    group_children, sources, resources = [], [], []
    for name in ("GameImportStore.swift", "GameImportActionViewController.swift"):
        ref = put(name, {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                         "path": "AetherGameImport/" + name, "sourceTree": "SOURCE_ROOT"})
        group_children.append(ref)
        sources.append(put(name + "-build", {"isa": "PBXBuildFile", "fileRef": ref}))
    for name in ("InfoPlist.strings", "Localizable.strings"):
        children = []
        for locale in sorted(extension_dir.glob("*.lproj")):
            if not (locale / name).exists():
                continue
            children.append(put(locale.name + "/" + name, {
                "isa": "PBXFileReference", "lastKnownFileType": "text.plist.strings",
                "name": locale.stem, "path": "AetherGameImport/" + locale.name + "/" + name,
                "sourceTree": "SOURCE_ROOT"}))
            append(root.setdefault("knownRegions", []), locale.stem)
        ref = put(name, {"isa": "PBXVariantGroup", "children": children, "name": name,
                         "sourceTree": "<group>"})
        group_children.append(ref)
        resources.append(put(name + "-build", {"isa": "PBXBuildFile", "fileRef": ref}))
    group_ref = put("group", {"isa": "PBXGroup", "name": "Game Import", "children": group_children,
                              "sourceTree": "<group>"})
    append(objects[root["mainGroup"]]["children"], group_ref)
    phases = []
    for phase, files in (("Sources", sources), ("Frameworks", []), ("Resources", resources)):
        phases.append(put(phase, {"isa": "PBX" + phase + "BuildPhase", "buildActionMask": "2147483647",
                                  "files": files, "runOnlyForDeploymentPostprocessing": "0"}))
    build_configs = []
    # Godot stores versions either in Info.plist or in build settings.
    main_info = plistlib.loads((export / configs[0]["buildSettings"]["INFOPLIST_FILE"].strip('"')).read_bytes())
    for config in configs:
        original = config["buildSettings"]
        settings = {
            "PRODUCT_NAME": "AetherGameImport", "PRODUCT_BUNDLE_IDENTIFIER": bundle + ".GameImport",
            "INFOPLIST_FILE": "AetherGameImport/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "AetherGameImport/GameImport.entitlements",
            "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": original.get("DEVELOPMENT_TEAM", ""),
            "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
            "OTHER_LDFLAGS": [], "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config["name"] == "Debug" else "-O",
            "MARKETING_VERSION": original.get("MARKETING_VERSION", main_info.get("CFBundleShortVersionString", "1.0")),
            "CURRENT_PROJECT_VERSION": original.get("CURRENT_PROJECT_VERSION", main_info.get("CFBundleVersion", "1")),
        }
        build_configs.append(put("config-" + config["name"], {"isa": "XCBuildConfiguration",
                                                            "name": config["name"], "buildSettings": settings}))
    config_list = put("configs", {"isa": "XCConfigurationList", "buildConfigurations": build_configs,
                                   "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release"})
    product = put("product", {"isa": "PBXFileReference", "explicitFileType": "wrapper.app-extension",
                               "includeInIndex": "0", "path": "AetherGameImport.appex", "sourceTree": "BUILT_PRODUCTS_DIR"})
    append(objects[root["productRefGroup"]]["children"], product)
    target = put("target", {"isa": "PBXNativeTarget", "name": "AetherGameImport", "productName": "AetherGameImport",
                             "buildConfigurationList": config_list, "buildPhases": phases, "buildRules": [],
                             "dependencies": [], "productReference": product,
                             "productType": "com.apple.product-type.app-extension"})
    append(root["targets"], target)
    proxy = put("proxy", {"isa": "PBXContainerItemProxy", "containerPortal": data["rootObject"],
                           "proxyType": "1", "remoteGlobalIDString": target, "remoteInfo": "AetherGameImport"})
    dependency = put("dependency", {"isa": "PBXTargetDependency", "target": target, "targetProxy": proxy})
    append(app.setdefault("dependencies", []), dependency)
    embed_file = put("embed-file", {"isa": "PBXBuildFile", "fileRef": product,
                                    "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy"]}})
    embed = put("embed", {"isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647", "dstPath": "",
                           "dstSubfolderSpec": "13", "files": [embed_file], "name": "Embed Game Import Extension",
                           "runOnlyForDeploymentPostprocessing": "0"})
    append(app["buildPhases"], embed)
    attributes = root.setdefault("attributes", {}).setdefault("TargetAttributes", {})
    for key in (app_id, target):
        attributes.setdefault(key, {}).setdefault("SystemCapabilities", {})["com.apple.ApplicationGroups.iOS"] = {"enabled": "1"}
    write_project(project, data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    stage(parser.parse_args().project.resolve())
