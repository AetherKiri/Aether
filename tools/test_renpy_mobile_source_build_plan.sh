#!/usr/bin/env bash
# Check source-build gating, pins and platform-aware prerequisites. No gameplay.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$repo_root/bridge/renpy_runtime/mobile_launcher/build.sh"
runner="$repo_root/tools/run_renpy_mobile_source_build.sh"
runner_tmp="$(mktemp -d "${TMPDIR:-/tmp}/renpy-mobile-source-runner.XXXXXX")"
trap 'rm -rf "$runner_tmp"' EXIT
bash -n "$runner"
bash -n "$launcher"
skip_output="$(AETHERKIRI_RENPY_BUILD_ROOT="$runner_tmp/missing" bash "$runner" --mode auto)"
grep -Fq 'source build skipped' <<<"$skip_output"
if AETHERKIRI_RENPY_SOURCE_BUILD_REQUIRED=1 AETHERKIRI_RENPY_BUILD_ROOT="$runner_tmp/missing" \
    bash "$runner" --mode auto >"$runner_tmp/required.stdout" 2>"$runner_tmp/required.stderr"; then
    echo "required source build unexpectedly skipped" >&2; exit 1
fi
grep -Fq 'requires an official renpy-build checkout' "$runner_tmp/required.stderr"
if bash "$runner" --ref master --mode prepare >"$runner_tmp/ref.stdout" 2>"$runner_tmp/ref.stderr"; then
    echo "unpinned build revision unexpectedly accepted" >&2; exit 1
fi
grep -Fq 'unsupported build revision' "$runner_tmp/ref.stderr"
bash "$launcher" --source-build-plan --renpy-build "$repo_root" --platform android >"$runner_tmp/plan"
for expected in '7bfab40c1174f622f644b24669afd5fb167fbb79' '39895c1e017f0b36ffea2447d97eccd69d76ee1c' \
    '65f8da82b13a1273e55a6bfcbd1f9da09fc4eb7a' '--python 3 rebuild librenpy pythonlib renpython rapt sdl2' \
    'librenpython.so' 'librenpython.a' 'does not assert mobile playability'; do
    grep -Fq -- "$expected" "$runner_tmp/plan"
done
if bash "$launcher" --check-renpy-build --renpy-build "$repo_root" --platform android >"$runner_tmp/check" 2>&1; then
    echo "strict preflight unexpectedly accepted the Aether checkout" >&2; exit 1
fi
grep -Fq 'Ren\x27Py source-build preflight failed' "$runner_tmp/check" || grep -Fq "Ren'Py source-build preflight failed" "$runner_tmp/check"
if grep -Fq 'missing toolchain archive:' "$runner_tmp/check"; then
    grep -Fq 'android-ndk-r29-linux.zip' "$runner_tmp/check"
    if grep -Eq '^missing toolchain archive:.*iPhone' "$runner_tmp/check"; then
        echo "Android-only preflight incorrectly requires a licensed iOS SDK" >&2; exit 1
    fi
fi
python3 - "$runner" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.index('apply_once "$renpy_build/renpy"') < source.index('./build.sh --platform android')
assert source.index('"$patch_root/native"/000[0-9]-*.patch') < source.index('./build.sh --platform android')
assert '"$mode" == "check" || "$mode" == "auto"' not in source, 'auto must not mean check-only'
for symbol in ('renpy_mobile_text_input_state', 'renpy_mobile_set_surface_size'):
    assert symbol in source
assert 'rapt-sdl2' not in source, 'pinned release has a sdl2 task, no rapt-sdl2 task'
PY
python3 - "$runner" "$runner_tmp" <<'PY'
from pathlib import Path
import subprocess
import sys
source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2])
symbols = source[source.index('symbols=('):source.index('\ncheck_exports()')]
function = source[source.index('check_exports()'):source.index('\nartifact_root=')]
catalog = root / 'large-symbol-catalog'
required = [name for name in symbols.replace('(', ' ').replace(')', ' ').split() if name.startswith('renpy_mobile_')]
catalog.write_text(''.join('000000 T ' + name + '\n' for name in required) +
                   ''.join(f'000000 T runtime_function_{i}\n' for i in range(20000)))
artifact = root / 'export-gate-library'
artifact.touch()
script = root / 'export-gate-check.sh'
script.write_text('set -euo pipefail\n' + symbols + '\n' + function + '\n' +
                  'nm() { cat "$RENPY_GATE_CATALOG"; }\n' +
                  'check_exports "$RENPY_GATE_ARTIFACT" android\n')
import os
environment = dict(os.environ, RENPY_GATE_CATALOG=str(catalog), RENPY_GATE_ARTIFACT=str(artifact))
subprocess.run(['bash', str(script)], env=environment, check=True)
catalog.write_text(catalog.read_text().replace('000000 T renpy_mobile_tick\n', ''))
failure = subprocess.run(['bash', str(script)], env=environment, capture_output=True, text=True)
assert failure.returncode != 0 and 'lacks renpy_mobile_tick' in failure.stderr
PY
echo "Ren'Py mobile source-build gating checks passed; no native build/gameplay performed"
