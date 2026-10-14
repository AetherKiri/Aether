#!/usr/bin/env python3
"""Embed native Ren'Py frameworks and loose Python resources in a Godot Xcode export."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def identifier(name):
    return hashlib.sha256(("AetherRenpy/" + name).encode()).hexdigest()[:24].upper()


def openstep(value, indent=0):
    space = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join("\t" + space + json.dumps(str(k)) + " = " + openstep(v, indent + 1) + ";\n" for k,v in value.items()) + space + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" + space + openstep(v, indent + 1) + ",\n" for v in value) + space + ")"
    if isinstance(value, bool): return "1" if value else "0"
    return json.dumps(str(value), ensure_ascii=False)


def stage(project, runtime):
    file = project / "project.pbxproj"
    data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(file)]))
    objects = data["objects"]
    root = objects[data["rootObject"]]
    targets = [objects[item] for item in root["targets"] if objects[item].get("isa") == "PBXNativeTarget"]
    if len(targets) != 1: raise ValueError("Expected one Godot app target")
    target = targets[0]
    export = project.parent
    source = export / "Aether"
    source.mkdir(exist_ok=True)
    shutil.copytree(runtime / "renpy-runtime", source / "renpy-runtime", dirs_exist_ok=True)
    shutil.copytree(runtime / "Frameworks", source / "renpy-frameworks", dirs_exist_ok=True)
    group_id = next((key for key, value in objects.items() if value.get("isa") == "PBXGroup" and value.get("path", value.get("name")) == "Aether"), root["mainGroup"])
    group = objects[group_id]
    def append_unique(array, value):
        if value not in array: array.append(value)
    resource_phase = next(objects[item] for item in target["buildPhases"] if objects[item].get("isa") == "PBXResourcesBuildPhase")
    reference, build = identifier("runtime-reference"), identifier("runtime-build")
    objects[reference] = {"isa":"PBXFileReference", "lastKnownFileType":"folder", "path":"Aether/renpy-runtime", "sourceTree":"SOURCE_ROOT"}
    objects[build] = {"isa":"PBXBuildFile", "fileRef":reference}
    append_unique(group.setdefault("children", []), reference)
    append_unique(resource_phase.setdefault("files", []), build)
    copy_id = identifier("frameworks-phase")
    objects[copy_id] = {"isa":"PBXCopyFilesBuildPhase", "buildActionMask":"2147483647", "dstPath":"", "dstSubfolderSpec":"10", "files":[], "name":"Embed Renpy Frameworks", "runOnlyForDeploymentPostprocessing":"0"}
    append_unique(target["buildPhases"], copy_id)
    for framework in (runtime / "Frameworks").glob("*.framework"):
        reference, build = identifier(framework.name), identifier(framework.name + "-embed")
        objects[reference] = {"isa":"PBXFileReference", "lastKnownFileType":"wrapper.framework", "path":"Aether/renpy-frameworks/" + framework.name, "sourceTree":"SOURCE_ROOT"}
        objects[build] = {"isa":"PBXBuildFile", "fileRef":reference, "settings":{"ATTRIBUTES":["CodeSignOnCopy", "RemoveHeadersOnCopy"]}}
        append_unique(group.setdefault("children", []), reference)
        objects[copy_id]["files"].append(build)
    file.write_text("// !$*UTF8*$!\n" + openstep(data) + "\n")
    subprocess.run(["plutil", "-lint", str(file)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    args = parser.parse_args()
    stage(args.project.resolve(), args.runtime.resolve())
