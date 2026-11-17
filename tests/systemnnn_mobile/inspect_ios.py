"""Inspect the iPhoneOS link probe without executing it."""
import json
import re
import subprocess
import sys
from pathlib import Path

binary = Path(sys.argv[1])
arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
if arch != "arm64":
    raise SystemExit(f"Expected arm64 iPhoneOS binary, observed {arch!r}")
loads = subprocess.check_output(["otool", "-l", str(binary)], text=True)
# LC_BUILD_VERSION's platform 2 is iOS; platform 7 would be iOS Simulator.
platforms = re.findall(r"\bplatform\s+(\S+)", loads)
if platforms not in (["2"], ["IOS"], ["iOS"]):
    raise SystemExit(f"Expected iPhoneOS LC_BUILD_VERSION platform, observed {platforms}")
minimums = re.findall(r"\bminos\s+(\S+)", loads)
symbols = subprocess.check_output(["nm", "-g", str(binary)], text=True)
for symbol in ("_aether_systemnnn_register_runtime", "_aether_systemnnn_mobile_link_probe"):
    if not any(line.split()[-1] == symbol and " U " not in line for line in symbols.splitlines() if line.split()):
        raise SystemExit(f"Missing defined symbol {symbol}")
libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
linked = [line.strip().split(" (", 1)[0] for line in libraries.splitlines()[1:]]
foreign = [name for name in linked if not name.startswith(("/System/Library/", "/usr/lib/"))]
if foreign:
    raise SystemExit(f"Unbundled non-system libraries in static iOS probe: {foreign}")
print(json.dumps({"binary": binary.name, "architecture": arch, "platform": "iOS", "minimum_os": minimums, "dynamic_libraries": linked}, indent=2))
