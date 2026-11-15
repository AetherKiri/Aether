#!/usr/bin/env python3
"""Publish an iOS NativeAOT host with its static runtime and bootstrap object."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--rid", choices=("ios-arm64", "iossimulator-arm64", "iossimulator-x64"), required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--minimum-version", default="16.0")
    parser.add_argument("--font", type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    # NativeLib=Static exports only the managed object. Ask the SDK for the
    # matching runtime closure instead of guessing NuGet package versions.
    with tempfile.TemporaryDirectory(prefix="aether-n2-ios-") as temporary:
        temporary = Path(temporary)
        targets = temporary / "closure.targets"
        targets.write_text("""<Project>
  <Target Name="ExportAetherNativeClosure" AfterTargets="Publish" DependsOnTargets="SetupOSSpecificProps">
    <WriteLinesToFile File="$(PublishDir)native-libraries.txt" Lines="@(NativeLibrary)" Overwrite="true" />
    <WriteLinesToFile File="$(PublishDir)native-frameworks.txt" Lines="@(NativeFramework)" Overwrite="true" />
    <WriteLinesToFile File="$(PublishDir)native-system-libraries.txt" Lines="@(NativeSystemLibrary)" Overwrite="true" />
  </Target>
</Project>
""")
        command = [args.dotnet, "publish", str(args.project.resolve()), "-c", "Release", "-r", args.rid,
                   f"/p:NativeRid={args.rid}", "/p:PublishAotUsingRuntimePack=true",
                   "/p:IlcExportUnmanagedEntrypoints=true", f"/p:AppleMinOSVersion={args.minimum_version}",
                   f"/p:CustomAfterMicrosoftCommonTargets={targets}", "-o", str(destination)]
        if args.font:
            command.append(f"/p:AetherRuntimeCjkFontPath={args.font.resolve()}")
        subprocess.run(command, check=True)
        managed = destination / "aether_n2system.a"
        if not managed.is_file():
            raise RuntimeError(f"NativeAOT static host is missing: {managed}")
        native = [Path(line) for line in (destination / "native-libraries.txt").read_text().splitlines() if line]
        if not native or any(not path.is_file() for path in native):
            raise RuntimeError("NativeAOT reported missing runtime archives")
        objects = [path for path in native if path.suffix == ".o"]
        if not any(path.name == "libbootstrapperdll.o" for path in objects):
            raise RuntimeError("NativeAOT library bootstrap object is missing")
        sdk = "iphonesimulator" if args.rid.startswith("iossimulator-") else "iphoneos"
        platform = "ios-simulator" if sdk == "iphonesimulator" else "ios"
        architecture = "x86_64" if args.rid.endswith("-x64") else "arm64"
        sdk_version = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True).strip()
        combined = temporary / "aether_n2system_initialized.o"
        # The bootstrap has only a C++ initializer, so an archive linker would
        # otherwise omit it. Put it in the same object as the exported ABI.
        # Keep private externs: the runtime archives reference generated helpers.
        subprocess.run(["xcrun", "ld", "-r", "-keep_private_externs", "-arch", architecture,
                        "-platform_version", platform, args.minimum_version, sdk_version,
                        "-force_load", str(managed), *map(str, objects), "-o", str(combined)], check=True)
        subprocess.run(["xcrun", "libtool", "-static", "-no_warning_for_no_symbols", "-o",
                        str(destination / "libaether_n2system_native.a"), str(combined),
                        *[str(path) for path in native if path.suffix != ".o"]], check=True)
        manifest = {"rid": args.rid, "minimum_version": args.minimum_version,
                    "frameworks": (destination / "native-frameworks.txt").read_text().splitlines(),
                    "system_libraries": (destination / "native-system-libraries.txt").read_text().splitlines()}
        (destination / "native-link.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
