#!/usr/bin/env bash
# Exercise input rejection and resource validation; fixtures are never apps.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/tools/validate_renpy_mobile_payload.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-packaging.XXXXXX")"
trap 'rm -rf "$work"' EXIT
bash -n "$repo_root/scripts/build_android.sh" "$repo_root/scripts/build_ios.sh" \
    "$repo_root/tools/stage_renpy_android_support.sh"

mkdir -p "$work/private/renpy/display" "$work/private/lib/python3.12/encodings"
for file in main.py renpy/__init__.py renpy/main.py renpy/execution.py \
    renpy/display/core.py lib/python3.12/site.py lib/python3.12/encodings/__init__.py; do
    printf '# packaging contract fixture\n' > "$work/private/$file"
done
cat > "$work/private/renpy/aether_mobile.py" <<'PY'
def cooperative_start(): pass
def cooperative_tick(): pass
def cooperative_stop(): pass
PY
python3 "$validator" --platform android --private-root "$work/private"
# The distribution carries sourceless Python 3.12 modules, so verify the
# actual bytecode-reading path as well as source resources.
python3 - "$work/private" <<'PY'
from pathlib import Path
import py_compile
import sys
for source in Path(sys.argv[1]).rglob('*.py'):
    if source.name == 'main.py' and source.parent == Path(sys.argv[1]):
        continue
    py_compile.compile(str(source), cfile=str(source.with_suffix('.pyc')), doraise=True)
    source.unlink()
PY
python3 "$validator" --platform android --private-root "$work/private"
rm "$work/private/renpy/aether_mobile.pyc"
if python3 "$validator" --platform android --private-root "$work/private" \
    > "$work/stdout" 2> "$work/stderr"; then
    echo 'packaging accepted a Python runtime without the cooperative module' >&2
    exit 1
fi
grep -Fq 'missing Python module' "$work/stderr"
ln -s /tmp "$work/private/escape"
if python3 "$validator" --platform android --private-root "$work/private" \
    > "$work/stdout" 2> "$work/stderr"; then
    echo 'packaging accepted an asset symlink' >&2
    exit 1
fi
grep -Fq 'must not contain symlinks' "$work/stderr"

# A host shared library must not be mislabeled as a mobile deliverable even
# when its function names resemble the lifecycle ABI.
printf 'int renpy_mobile_init(void) { return 0; }\n' > "$work/host.c"
"${CC:-cc}" -shared -fPIC "$work/host.c" -o "$work/host.so"
if python3 "$validator" --platform android --library "$work/host.so" \
    > "$work/stdout" 2> "$work/stderr"; then
    echo 'packaging accepted a host shared library as Android arm64' >&2
    exit 1
fi
grep -Eq 'must target arm64-v8a|must be a little-endian ELF64' "$work/stderr"

echo "Ren'Py mobile packaging rejection/resource checks passed; no mobile app executed"
