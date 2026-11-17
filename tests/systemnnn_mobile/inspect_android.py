"""Inspect the linked Android package without executing target code."""
import json
import re
import subprocess
import sys
from pathlib import Path

package, readelf = Path(sys.argv[1]), sys.argv[2]
observations = []
provided = {path.name for path in (package / "lib").glob("*.so")}
platform = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so", "libOpenSLES.so", "libaaudio.so", "libmediandk.so", "libz.so"}
for name in ("libsystemnnn-mobile-link.so", "libengine_api.so", "libc++_shared.so"):
    binary = package / "lib" / name
    output = subprocess.check_output([readelf, "--wide", "-h", "-l", "-d", "-s", str(binary)], text=True)
    if not re.search(r"Machine:\s+AArch64", output):
        raise SystemExit(f"{name}: expected AArch64")
    alignments = [int(line.split()[-1], 16) for line in output.splitlines() if line.strip().startswith("LOAD ")]
    if not alignments or min(alignments) < 16384:
        raise SystemExit(f"{name}: LOAD alignment below 16 KiB: {alignments}")
    needed = re.findall(r"\(NEEDED\).*?\[([^]]+)\]", output)
    missing = set(needed) - provided - platform
    if missing:
        raise SystemExit(f"{name}: unbundled non-platform dependencies: {sorted(missing)}")
    if name == "libsystemnnn-mobile-link.so":
        for symbol in ("aether_systemnnn_mobile_link_probe", "aether_systemnnn_register_runtime"):
            if not any(symbol == line.split()[-1] and " UND " not in line for line in output.splitlines() if line.split()):
                raise SystemExit(f"{name}: missing defined symbol {symbol}")
    observations.append({"binary": name, "machine": "AArch64", "load_alignments": alignments, "needed": needed})
print(json.dumps(observations, indent=2))
