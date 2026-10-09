#!/usr/bin/env bash
# Real host Godot Variant regression, not Android Java/JNI or gameplay proof.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
work="$(mktemp -d "${TMPDIR:-/tmp}/aether-java-boolean.XXXXXX")"
trap 'rm -rf "$work"' EXIT
[[ "$(uname -s)" == Linux ]] || { echo 'This host ABI test currently supports Linux' >&2; exit 1; }
mkdir -p "$work/project/.godot" "$work/xdg/data" "$work/xdg/config" "$work/xdg/cache"
export XDG_DATA_HOME="$work/xdg/data" XDG_CONFIG_HOME="$work/xdg/config" XDG_CACHE_HOME="$work/xdg/cache"
cat > "$work/project/project.godot" <<'PROJECT'
config_version=5
[application]
config/name="RenPy Java boolean boundary"
[rendering]
renderer/rendering_method="gl_compatibility"
PROJECT
"$godot_bin" --headless --path "$work/project" --dump-gdextension-interface --dump-extension-api
python3 - "$work/project/extension_api.json" "$work/sizes.h" <<'PY'
import json, struct, sys
api = json.load(open(sys.argv[1]))
precision = 'double' if api['header']['precision'] == 'double' else 'float'
configuration = f'{precision}_{struct.calcsize("P") * 8}'
sizes = next(x['sizes'] for x in api['builtin_class_sizes'] if x['build_configuration'] == configuration)
sizes = {x['name']: x['size'] for x in sizes}
with open(sys.argv[2], 'w') as f:
    f.write(f'#define AETHER_TEST_VARIANT_SIZE {sizes["Variant"]}\n')
    f.write(f'#define AETHER_TEST_STRING_SIZE {sizes["String"]}\n')
PY
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -fPIC -shared \
    -include "$work/sizes.h" -I"$work/project" -I"$repo_root/bridge/renpy_runtime/include" \
    "$repo_root/bridge/renpy_runtime/tests/java_boolean_godot.cpp" -o "$work/project/variant_test.so"
cat > "$work/project/variant_test.gdextension" <<'EXTENSION'
[configuration]
entry_symbol="aether_java_boolean_test_init"
compatibility_minimum="4.1"
[libraries]
linux="res://variant_test.so"
EXTENSION
printf '%s\n' 'res://variant_test.gdextension' > "$work/project/.godot/extension_list.cfg"
cat > "$work/project/quit.gd" <<'SCRIPT'
extends SceneTree
func _initialize() -> void:
    quit(0)
SCRIPT
export AETHER_VARIANT_RESULT="$work/result.json"
"$godot_bin" --headless --path "$work/project" --script "$work/project/quit.gd"
python3 - "$work/result.json" "$work/project/extension_api.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
api = json.load(open(sys.argv[2]))['header']
assert result['passed'] and result['checks'] == 12, result
assert result['godot'] == '.'.join(str(api[k]) for k in ('version_major', 'version_minor', 'version_patch')), result
assert result['android_java_executed'] is False, result
print(json.dumps(result, sort_keys=True))
PY
