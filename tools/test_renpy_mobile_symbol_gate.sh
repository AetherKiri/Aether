#!/usr/bin/env bash
# Validate the host lifecycle export surface without claiming mobile playability.
#
# With no artifact paths this runs a deterministic shared-library fixture and
# a negative missing-symbol check. CI can pass RENPY_MOBILE_ANDROID_SO and/or
# RENPY_MOBILE_IOS_A to gate a rebuilt native payload once one is available.
set -euo pipefail

required_symbols=(
    renpy_mobile_init
    renpy_mobile_tick
    renpy_mobile_frame
    renpy_mobile_input
    renpy_mobile_pause
    renpy_mobile_resume
    renpy_mobile_shutdown
)

nm_listing() {
    local artifact="$1" kind="$2"
    [[ -f "$artifact" ]] || {
        echo "lifecycle artifact does not exist: $artifact" >&2
        return 1
    }
    local listing
    listing="$(mktemp)"
    case "$kind" in
        shared)
            if ! nm -D --defined-only "$artifact" >"$listing" 2>/dev/null; then
                nm -gU "$artifact" >"$listing"
            fi
            ;;
        static)
            if ! nm -gU "$artifact" >"$listing" 2>/dev/null; then
                nm -g "$artifact" >"$listing"
            fi
            ;;
        *) echo "unknown artifact kind: $kind" >&2; rm -f "$listing"; return 2 ;;
    esac
    printf '%s\n' "$listing"
}

check_symbols() {
    local artifact="$1" kind="$2" listing
    listing="$(nm_listing "$artifact" "$kind")"
    local missing=0 symbol
    for symbol in "${required_symbols[@]}"; do
        if ! awk '{print $NF}' "$listing" | sed 's/^_//' | grep -Fxq "${symbol}"; then
            echo "missing lifecycle export: ${symbol} (${artifact})" >&2
            missing=1
        fi
    done
    rm -f "$listing"
    ((missing == 0))
}

check_optional_artifact() {
    local variable_name="$1" kind="$2" artifact=""
    if [[ -n "${!variable_name+x}" ]]; then
        artifact="${!variable_name}"
    fi
    if [[ -n "$artifact" ]]; then
        echo "Checking lifecycle exports from ${variable_name}: ${artifact}"
        check_symbols "$artifact" "$kind"
    fi
}

check_optional_artifact RENPY_MOBILE_ANDROID_SO shared
check_optional_artifact RENPY_MOBILE_IOS_A static

work="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-symbol-gate.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat >"$work/fixture.c" <<'C'
#define EXPORT __attribute__((visibility("default")))
EXPORT int renpy_mobile_init(void) { return 0; }
EXPORT int renpy_mobile_tick(void) { return 0; }
EXPORT int renpy_mobile_frame(void) { return 0; }
EXPORT int renpy_mobile_input(void) { return 0; }
EXPORT int renpy_mobile_pause(void) { return 0; }
EXPORT int renpy_mobile_resume(void) { return 0; }
EXPORT void renpy_mobile_shutdown(void) {}
C
"${CC:-cc}" -shared -fPIC "$work/fixture.c" -o "$work/librenpython.so"
check_symbols "$work/librenpython.so" shared

cat >"$work/missing.c" <<'C'
int renpy_mobile_init(void) { return 0; }
C
"${CC:-cc}" -shared -fPIC "$work/missing.c" -o "$work/librenpython-missing.so"
if check_symbols "$work/librenpython-missing.so" shared; then
    echo "missing lifecycle export fixture unexpectedly passed" >&2
    exit 1
fi

echo "Ren'Py mobile lifecycle export gate passed (fixture + negative check)"
