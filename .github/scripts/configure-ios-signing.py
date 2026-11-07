#!/usr/bin/env python3
"""Validate both import profiles and assign signing per target, never globally."""
import argparse
from pathlib import Path
import plistlib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from stage_ios_game_import import GROUP_KEY, configurations, read_project, write_project


def configure(project, bundle, team, profiles, export_options):
    data = read_project(project)
    objects = data["objects"]
    targets = [objects[key] for key in objects[data["rootObject"]]["targets"]]
    group = "group." + bundle + ".game-import"
    export_profiles = {}
    expected = {bundle: "com.apple.product-type.application", bundle + ".GameImport": "com.apple.product-type.app-extension"}
    for identifier, profile_path in zip(expected, profiles):
        profile = plistlib.loads(profile_path.read_bytes())
        entitlements = profile.get("Entitlements", {})
        if profile.get("TeamIdentifier") != [team]:
            raise ValueError(f"Profile {profile_path.name} must belong to team {team}")
        if entitlements.get("application-identifier") != team + "." + identifier:
            raise ValueError(f"Profile {profile_path.name} must target {identifier}")
        if group not in entitlements.get(GROUP_KEY, []):
            raise ValueError(f"Profile {profile_path.name} must include App Group {group}; regenerate it after enabling the capability")
        matches = [t for t in targets if t.get("productType") == expected[identifier]
                   and all(c["buildSettings"].get("PRODUCT_BUNDLE_IDENTIFIER") == identifier
                           for c in configurations(objects, t))]
        if len(matches) != 1:
            raise ValueError(f"Expected one staged target with bundle ID {identifier}")
        for config in configurations(objects, matches[0]):
            settings = config["buildSettings"]
            entitlement_path = project.parent / settings["CODE_SIGN_ENTITLEMENTS"].strip('"')
            if group not in plistlib.loads(entitlement_path.read_bytes()).get(GROUP_KEY, []):
                raise ValueError(f"Target {identifier} is missing its App Group entitlement")
            settings.update(CODE_SIGN_STYLE="Manual", DEVELOPMENT_TEAM=team,
                            CODE_SIGN_IDENTITY="Apple Distribution", PROVISIONING_PROFILE_SPECIFIER=profile["UUID"])
        export_profiles[identifier] = profile["UUID"]
    # Write only after all profiles and targets pass validation.
    write_project(project, data)
    export_options.write_bytes(plistlib.dumps({
        "method": "app-store-connect", "teamID": team, "signingStyle": "manual",
        "signingCertificate": "Apple Distribution", "manageAppVersionAndBuildNumber": False,
        "stripSwiftSymbols": True, "uploadSymbols": False, "provisioningProfiles": export_profiles,
    }))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--app-profile", type=Path, required=True)
    parser.add_argument("--import-profile", type=Path, required=True)
    parser.add_argument("--export-options", type=Path, required=True)
    args = parser.parse_args()
    configure(args.project.resolve(), args.bundle_id, args.team_id,
              [args.app_profile, args.import_profile], args.export_options)
